import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../services/session_manager.dart';
import '../stability/security_event_service.dart';
import '../stability/security_observability_service.dart';
import '../services/error_logger.dart';
import '../stability/checkout_guard_service.dart';
import '../stability/realtime_presence_service.dart';
import '../stability/stability_logger.dart';
import '../stability/stability_metrics_service.dart';

typedef RealtimeChannelBuilder = RealtimeChannel Function(
  SupabaseClient client,
  String channelName,
);

typedef RealtimeSubscribedCallback = FutureOr<void> Function(
  bool didReconnect,
);

class RealtimeChannelController {
  static final Set<RealtimeChannelController> _activeControllers =
      <RealtimeChannelController>{};

  static Future<void> terminateAllAuthenticatedChannels({
    required String reason,
  }) async {
    final controllers =
        List<RealtimeChannelController>.from(_activeControllers);
    for (final controller in controllers) {
      await controller._forceTerminateAuthChannels(reason: reason);
    }
  }

  RealtimeChannelController({
    required SupabaseClient client,
    required String topicPrefix,
    this.onSubscribed,
  })  : _client = client,
        _topicPrefix = topicPrefix;

  final SupabaseClient _client;
  final String _topicPrefix;
  final RealtimeSubscribedCallback? onSubscribed;

  RealtimeChannel? _channel;
  RealtimeChannelBuilder? _builder;
  StreamSubscription<AuthState>? _authSubscription;
  Timer? _restartTimer;
  Timer? _heartbeatTimer;
  bool _disposed = false;
  bool _hasSubscribedOnce = false;
  bool _jwtRefreshInFlight = false;
  bool _replaceInFlight = false;
  bool _replaceQueued = false;
  bool _authRevalidationInFlight = false;
  bool _authTerminated = false;
  bool _suspendedForMissingSession = false;
  bool _presenceRegistered = false;
  int _restartAttempts = 0;
  int _subscriptionGeneration = 0;
  DateTime? _lastStatusAt;

  void subscribe(
    RealtimeChannelBuilder builder, {
    bool resetConnectionState = false,
  }) {
    _builder = builder;
    _authTerminated = false;
    _ensureAuthLifecycleHook();
    if (resetConnectionState) {
      _hasSubscribedOnce = false;
    }
    _activeControllers.add(this);
    unawaited(StabilityMetricsService.instance.initialize());
    if (!_presenceRegistered) {
      RealtimePresenceService.instance.register(_topicPrefix);
      _presenceRegistered = true;
    }
    _startHeartbeatWatcher();
    _restartTimer?.cancel();
    _queueReplaceChannel();
  }

  Future<void> clear() async {
    _restartTimer?.cancel();
    _restartTimer = null;
    final channel = _channel;
    _channel = null;
    if (channel == null) {
      return;
    }

    try {
      await _client.removeChannel(channel);
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'realtime_channel_controller.clear.$_topicPrefix',
        error: error,
        stack: stack,
      );
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    _activeControllers.remove(this);
    _builder = null;
    await _authSubscription?.cancel();
    _authSubscription = null;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    if (_presenceRegistered) {
      RealtimePresenceService.instance.unregister(_topicPrefix);
      _presenceRegistered = false;
    }
    await clear();
  }

  void _queueReplaceChannel() {
    if (_disposed || _authTerminated || _suspendedForMissingSession) {
      return;
    }
    if (_replaceInFlight) {
      _replaceQueued = true;
      return;
    }
    unawaited(_replaceChannel());
  }

  Future<void> _replaceChannel() async {
    if (_replaceInFlight || _disposed) {
      return;
    }
    _replaceInFlight = true;
    try {
      final builder = _builder;
      if (_disposed || builder == null) {
        return;
      }

      final previousChannel = _channel;
      _channel = null;
      if (previousChannel != null) {
        await _client.removeChannel(previousChannel);
      }

      if (_disposed) {
        return;
      }

      await SessionManager.instance.ensureValidSession(
        requireSession: false,
      );
      final validSession = _client.auth.currentSession;
      if (validSession == null) {
        await _suspendUntilAuthenticated(reason: 'missing_session');
        return;
      }
      if (_disposed) {
        return;
      }

      final generation = ++_subscriptionGeneration;
      final channelName =
          '$_topicPrefix-${DateTime.now().microsecondsSinceEpoch}';
      final channel = builder(_client, channelName);
      _channel = channel;

      channel.subscribe((status, [error]) {
        if (_disposed ||
            !identical(_channel, channel) ||
            generation != _subscriptionGeneration) {
          return;
        }
        _lastStatusAt = DateTime.now().toUtc();
        RealtimePresenceService.instance.markHeartbeat(_topicPrefix);

        switch (status) {
          case RealtimeSubscribeStatus.subscribed:
            _restartTimer?.cancel();
            _restartTimer = null;
            _restartAttempts = 0;
            RealtimePresenceService.instance.markReconnectSucceeded(
              _topicPrefix,
            );
            _suspendedForMissingSession = false;
            final didReconnect = _hasSubscribedOnce;
            _hasSubscribedOnce = true;
            StabilityLogger.realtime(
              'Realtime channel subscribed topic=$_topicPrefix didReconnect=$didReconnect',
            );
            if (onSubscribed != null) {
              unawaited(_handleSubscribed(didReconnect));
            }
            break;
          case RealtimeSubscribeStatus.channelError:
          case RealtimeSubscribeStatus.timedOut:
            final jwtExpired = _isJwtExpiredSignal(error);
            unawaited(
              ErrorLogger.logError(
                module: 'realtime_channel_controller.subscribe.$_topicPrefix',
                error: error ?? Exception('Realtime status: $status'),
                action: status.name,
              ),
            );
            StabilityMetricsService.instance.increment(
              'reconnect_failures',
              module: 'realtime',
              payload: {'topic': _topicPrefix, 'status': status.name},
            );
            if (jwtExpired) {
              unawaited(_refreshSessionAndResubscribe());
              return;
            }
            if (_isAuthRevalidationFailure(error)) {
              unawaited(
                _forceTerminateAuthChannels(
                  reason: 'channel_auth_revalidation_failed',
                ),
              );
              return;
            }
            _scheduleRestart(reason: status.name);
            break;
          case RealtimeSubscribeStatus.closed:
            unawaited(
              ErrorLogger.logError(
                module: 'realtime_channel_controller.subscribe.$_topicPrefix',
                error: Exception('Realtime channel closed unexpectedly.'),
                action: status.name,
              ),
            );
            StabilityMetricsService.instance.increment(
              'reconnect_failures',
              module: 'realtime',
              payload: {'topic': _topicPrefix, 'status': status.name},
            );
            _scheduleRestart(reason: status.name);
            break;
        }
      });
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'realtime_channel_controller.replace.$_topicPrefix',
        error: error,
        stack: stack,
      );
      _scheduleRestart(reason: 'replace_exception');
    } finally {
      _replaceInFlight = false;
      if (_replaceQueued && !_disposed) {
        _replaceQueued = false;
        _queueReplaceChannel();
      }
    }
  }

  Future<void> _handleSubscribed(bool didReconnect) async {
    try {
      await onSubscribed!(didReconnect);
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'realtime_channel_controller.onSubscribed.$_topicPrefix',
        error: error,
        stack: stack,
      );
    }
  }

  void _scheduleRestart({required String reason}) {
    if (_disposed || _builder == null) {
      return;
    }
    _restartAttempts += 1;
    RealtimePresenceService.instance.markReconnectScheduled(_topicPrefix);
    final delay = RealtimePresenceService.instance.reconnectDelay(_topicPrefix);

    if (_restartAttempts >= 5) {
      StabilityLogger.realtime(
        'Realtime reconnect loop topic=$_topicPrefix attempts=$_restartAttempts reason=$reason',
      );
      StabilityMetricsService.instance.increment(
        'reconnect_failures',
        module: 'realtime',
        payload: {
          'topic': _topicPrefix,
          'reason': 'reconnect_loop',
          'attempts': _restartAttempts,
        },
      );
      unawaited(
        ErrorLogger.logError(
          module: 'realtime_channel_controller.reconnect_loop.$_topicPrefix',
          action: 'restart_attempt_$_restartAttempts',
          error: Exception(
            'Realtime reconnect loop detected ($_restartAttempts attempts).',
          ),
        ),
      );
      unawaited(
        CheckoutGuardService.instance.activateSafeMode(
          reason: 'realtime_unstable',
        ),
      );
    }

    _restartTimer?.cancel();
    _restartTimer = Timer(delay, () {
      if (_disposed || _builder == null) {
        return;
      }
      _queueReplaceChannel();
    });
  }

  Future<void> _refreshSessionAndResubscribe() async {
    if (_disposed || _builder == null || _jwtRefreshInFlight) {
      return;
    }

    _jwtRefreshInFlight = true;
    try {
      await SessionManager.instance.ensureValidSession(
        requireSession: false,
      );
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'realtime_channel_controller.refresh_session.$_topicPrefix',
        error: error,
        stack: stack,
      );
      _scheduleRestart(reason: 'refresh_failed');
      return;
    } finally {
      _jwtRefreshInFlight = false;
    }

    if (_disposed || _builder == null) {
      return;
    }
    if (_client.auth.currentSession == null) {
      await _suspendUntilAuthenticated(reason: 'refresh_missing_session');
      return;
    }

    _restartTimer?.cancel();
    _queueReplaceChannel();
  }

  void _startHeartbeatWatcher() {
    if (_heartbeatTimer != null) {
      return;
    }
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 35), (_) {
      if (_disposed || _channel == null) {
        return;
      }
      unawaited(_revalidateAuthState());
      final last = _lastStatusAt;
      if (last == null) {
        return;
      }
      if (DateTime.now().toUtc().difference(last) >
          const Duration(seconds: 90)) {
        StabilityMetricsService.instance.increment(
          'stale_realtime_subscriptions',
          module: 'realtime',
          payload: {'topic': _topicPrefix},
        );
        _scheduleRestart(reason: 'heartbeat_stale');
      }
    });
  }

  Future<void> _revalidateAuthState() async {
    if (_disposed || _authRevalidationInFlight || _authTerminated) {
      return;
    }
    _authRevalidationInFlight = true;
    try {
      final session = await SessionManager.instance.ensureValidSession(
        requireSession: false,
      );
      if (session != null) {
        return;
      }
      await _suspendUntilAuthenticated(reason: 'auth_session_invalid');
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'realtime_channel_controller.auth_revalidation.$_topicPrefix',
        error: error,
        stack: stack,
      );
      await _forceTerminateAuthChannels(reason: 'auth_revalidation_exception');
    } finally {
      _authRevalidationInFlight = false;
    }
  }

  Future<void> _forceTerminateAuthChannels({required String reason}) async {
    if (_disposed) {
      return;
    }
    _authTerminated = true;
    _suspendedForMissingSession = false;
    _restartTimer?.cancel();
    _restartTimer = null;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    await clear();
    StabilityLogger.authRevalidation(
      '[AUTH_REVALIDATION] Terminated realtime channel topic=$_topicPrefix reason=$reason',
    );
    SecurityObservabilityService.instance.incrementLocal(
      'auth_channel_kills',
      payload: {'topic': _topicPrefix, 'reason': reason},
    );
    SecurityEventService.instance.record(
      eventKey: 'realtime_auth_channel_terminated',
      severity: 'high',
      payload: {'topic': _topicPrefix, 'reason': reason},
    );
  }

  void _ensureAuthLifecycleHook() {
    if (_authSubscription != null) {
      return;
    }
    _authSubscription = _client.auth.onAuthStateChange.listen((event) {
      if (_disposed) {
        return;
      }
      final session = event.session ?? _client.auth.currentSession;
      if (session == null) {
        unawaited(_suspendUntilAuthenticated(reason: 'signed_out'));
        return;
      }

      if (_suspendedForMissingSession) {
        _authTerminated = false;
        _suspendedForMissingSession = false;
        _restartAttempts = 0;
        _startHeartbeatWatcher();
        _queueReplaceChannel();
        return;
      }

      if (_channel == null && !_authTerminated && _builder != null) {
        _queueReplaceChannel();
      }
    });
  }

  Future<void> _suspendUntilAuthenticated({required String reason}) async {
    if (_disposed) {
      return;
    }
    final alreadySuspended = _suspendedForMissingSession;
    _suspendedForMissingSession = true;
    _authTerminated = false;
    _restartTimer?.cancel();
    _restartTimer = null;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    await clear();
    if (alreadySuspended) {
      return;
    }
    StabilityLogger.authRevalidation(
      '[AUTH_REVALIDATION] Suspended realtime channel topic=$_topicPrefix reason=$reason awaiting_authenticated_session',
    );
  }

  bool _isJwtExpiredSignal(Object? error) {
    final message = error?.toString().toLowerCase() ?? '';
    if (message.isEmpty) {
      return false;
    }

    return message.contains('invalidjwttoken') ||
        message.contains('invalid jwt') ||
        message.contains('jwt expired') ||
        message.contains('token has expired') ||
        message.contains('session expired') ||
        message.contains('refresh token');
  }

  bool _isAuthRevalidationFailure(Object? error) {
    final message = error?.toString().toLowerCase() ?? '';
    if (message.isEmpty) {
      return false;
    }
    return message.contains('permission denied') ||
        message.contains('not authorized') ||
        message.contains('row level security') ||
        message.contains('forbidden') ||
        message.contains('revoked');
  }
}
