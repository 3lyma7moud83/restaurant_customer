import 'dart:async';

import 'package:flutter/foundation.dart';
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

enum RealtimeConnectionLifecycle {
  disconnected,
  connecting,
  connected,
  reconnecting,
}

class RealtimeChannelController {
  static final Set<RealtimeChannelController> _activeControllers =
      <RealtimeChannelController>{};
  static final Map<String, RealtimeChannelController> _channelRegistry =
      <String, RealtimeChannelController>{};
  static int _debugActiveChannelsCount = 0;
  static int _debugActiveListenersCount = 0;
  static int _debugActiveTimersCount = 0;

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
  RealtimeConnectionLifecycle _lifecycle =
      RealtimeConnectionLifecycle.disconnected;
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

  static Map<String, int> debugResourceCounts() {
    if (!kDebugMode) {
      return const <String, int>{};
    }
    return <String, int>{
      'activeChannelsCount': _debugActiveChannelsCount,
      'activeListenersCount': _debugActiveListenersCount,
      'activeTimersCount': _debugActiveTimersCount,
    };
  }

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
    _registerSingleActiveTopicOwner();
    unawaited(StabilityMetricsService.instance.initialize());
    if (!_presenceRegistered) {
      RealtimePresenceService.instance.register(_topicPrefix);
      _presenceRegistered = true;
    }
    _startHeartbeatWatcher();
    _cancelRestartTimer();
    _queueReplaceChannel();
  }

  Future<void> clear() async {
    _logCleanupStarted(reason: 'clear');
    _cancelRestartTimer();
    _setLifecycle(RealtimeConnectionLifecycle.disconnected);
    final channel = _channel;
    _channel = null;
    if (channel == null) {
      _logCleanupFinished(reason: 'clear');
      return;
    }

    await _removeChannel(channel, reason: 'clear');
    _logCleanupFinished(reason: 'clear');
  }

  Future<void> dispose() async {
    _logCleanupStarted(reason: 'dispose');
    _disposed = true;
    _activeControllers.remove(this);
    if (identical(_channelRegistry[_topicPrefix], this)) {
      _channelRegistry.remove(_topicPrefix);
    }
    _builder = null;
    await _disposeAuthListener();
    _cancelHeartbeatTimer();
    if (_presenceRegistered) {
      RealtimePresenceService.instance.unregister(_topicPrefix);
      _presenceRegistered = false;
    }
    await clear();
    _logCleanupFinished(reason: 'dispose');
  }

  void _queueReplaceChannel() {
    if (_disposed || _authTerminated || _suspendedForMissingSession) {
      return;
    }
    if (!_hasAuthenticatedUser) {
      unawaited(_suspendUntilAuthenticated(reason: 'missing_current_user'));
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

      final user = _client.auth.currentUser;
      if (user == null) {
        await _suspendUntilAuthenticated(reason: 'missing_current_user');
        return;
      }

      _setLifecycle(
        _hasSubscribedOnce
            ? RealtimeConnectionLifecycle.reconnecting
            : RealtimeConnectionLifecycle.connecting,
      );

      final previousChannel = _channel;
      _channel = null;
      if (previousChannel != null) {
        await _removeChannel(previousChannel, reason: 'replace');
      }

      if (_disposed) {
        return;
      }

      await SessionManager.instance.ensureValidSession(
        requireSession: false,
      );
      if (_client.auth.currentUser == null) {
        await _suspendUntilAuthenticated(reason: 'missing_current_user');
        return;
      }
      if (_disposed) {
        return;
      }

      final generation = ++_subscriptionGeneration;
      final channelName = _stableChannelName(_client.auth.currentUser!.id);
      final channel = builder(_client, channelName);
      _channel = channel;
      _incrementDebugChannels();
      StabilityLogger.realtime(
        'Subscription Created topic=$_topicPrefix channel=$channelName',
      );

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
            _cancelRestartTimer();
            _restartAttempts = 0;
            _setLifecycle(RealtimeConnectionLifecycle.connected);
            RealtimePresenceService.instance.markReconnectSucceeded(
              _topicPrefix,
            );
            _suspendedForMissingSession = false;
            final didReconnect = _hasSubscribedOnce;
            _hasSubscribedOnce = true;
            StabilityLogger.realtime(
              didReconnect
                  ? 'Reconnect Success topic=$_topicPrefix'
                  : 'Connection Opened topic=$_topicPrefix',
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
            _setLifecycle(RealtimeConnectionLifecycle.disconnected);
            StabilityLogger.realtime(
              'Connection Closed topic=$_topicPrefix',
            );
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
    if (!_hasAuthenticatedUser) {
      unawaited(_suspendUntilAuthenticated(reason: 'restart_missing_user'));
      return;
    }
    _restartAttempts += 1;
    _setLifecycle(RealtimeConnectionLifecycle.reconnecting);
    RealtimePresenceService.instance.markReconnectScheduled(_topicPrefix);
    final delay = RealtimePresenceService.instance.reconnectDelay(_topicPrefix);
    StabilityLogger.realtime(
      'Reconnect Started topic=$_topicPrefix attempt=$_restartAttempts delay=${delay.inMilliseconds}ms reason=$reason',
    );

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

    _cancelRestartTimer();
    _incrementDebugTimers();
    _restartTimer = Timer(delay, () {
      _restartTimer = null;
      _decrementDebugTimers();
      if (_disposed || _builder == null) {
        return;
      }
      if (!_hasAuthenticatedUser) {
        unawaited(_suspendUntilAuthenticated(reason: 'retry_missing_user'));
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
    if (_client.auth.currentUser == null) {
      await _suspendUntilAuthenticated(reason: 'refresh_missing_current_user');
      return;
    }

    _cancelRestartTimer();
    _queueReplaceChannel();
  }

  void _startHeartbeatWatcher() {
    if (_heartbeatTimer != null) {
      return;
    }
    _incrementDebugTimers();
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
    _logCleanupStarted(reason: reason);
    _cancelRestartTimer();
    _cancelHeartbeatTimer();
    await clear();
    _logCleanupFinished(reason: reason);
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
    _incrementDebugListeners();
    _authSubscription = _client.auth.onAuthStateChange.listen((event) {
      if (_disposed) {
        return;
      }
      final user = event.session?.user ?? _client.auth.currentUser;
      StabilityLogger.realtime(
        'Auth Session Changed topic=$_topicPrefix event=${event.event.name} authenticated=${user != null}',
      );
      if (user == null) {
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
    _logCleanupStarted(reason: reason);
    _cancelRestartTimer();
    _cancelHeartbeatTimer();
    await clear();
    if (alreadySuspended) {
      return;
    }
    StabilityLogger.authRevalidation(
      '[AUTH_REVALIDATION] Suspended realtime channel topic=$_topicPrefix reason=$reason awaiting_authenticated_session',
    );
  }

  void _registerSingleActiveTopicOwner() {
    final currentOwner = _channelRegistry[_topicPrefix];
    if (currentOwner == null || identical(currentOwner, this)) {
      _channelRegistry[_topicPrefix] = this;
      return;
    }

    StabilityMetricsService.instance.increment(
      'duplicate_realtime_subscriptions',
      module: 'realtime',
      payload: {'topic': _topicPrefix},
    );
    StabilityLogger.realtime(
      'Duplicate realtime topic replaced topic=$_topicPrefix',
    );
    unawaited(
      currentOwner._forceTerminateAuthChannels(
        reason: 'duplicate_topic_replaced',
      ),
    );
    _channelRegistry[_topicPrefix] = this;
  }

  void _setLifecycle(RealtimeConnectionLifecycle next) {
    if (_lifecycle == next) {
      return;
    }
    _lifecycle = next;
  }

  String _stableChannelName(String userId) {
    final rawTopic = 'customer:$_topicPrefix:$userId';
    return rawTopic.replaceAll(RegExp(r'[^A-Za-z0-9:_-]'), '_');
  }

  bool get _hasAuthenticatedUser => _client.auth.currentUser != null;

  Future<void> _removeChannel(
    RealtimeChannel channel, {
    required String reason,
  }) async {
    try {
      await _client.removeChannel(channel);
      _decrementDebugChannels();
      StabilityLogger.realtime(
        'Channel Removed Successfully topic=$_topicPrefix reason=$reason',
      );
      StabilityLogger.realtime(
        'Subscription Removed topic=$_topicPrefix',
      );
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'realtime_channel_controller.remove.$_topicPrefix',
        action: reason,
        error: error,
        stack: stack,
      );
    }
  }

  void _cancelRestartTimer() {
    final timer = _restartTimer;
    if (timer == null) {
      return;
    }
    timer.cancel();
    _restartTimer = null;
    _decrementDebugTimers();
    StabilityLogger.realtime(
      'Timer Cancelled topic=$_topicPrefix timer=restart',
    );
  }

  void _cancelHeartbeatTimer() {
    final timer = _heartbeatTimer;
    if (timer == null) {
      return;
    }
    timer.cancel();
    _heartbeatTimer = null;
    _decrementDebugTimers();
    StabilityLogger.realtime(
      'Timer Cancelled topic=$_topicPrefix timer=heartbeat',
    );
  }

  Future<void> _disposeAuthListener() async {
    final subscription = _authSubscription;
    if (subscription == null) {
      return;
    }
    await subscription.cancel();
    _authSubscription = null;
    _decrementDebugListeners();
    StabilityLogger.realtime(
      'Listener Disposed topic=$_topicPrefix listener=auth_state',
    );
  }

  void _logCleanupStarted({required String reason}) {
    StabilityLogger.realtime(
      'Realtime Cleanup Started topic=$_topicPrefix reason=$reason',
    );
    _logDebugResourceCounts();
  }

  void _logCleanupFinished({required String reason}) {
    StabilityLogger.realtime(
      'Realtime Cleanup Finished topic=$_topicPrefix reason=$reason',
    );
    _logDebugResourceCounts();
  }

  void _incrementDebugChannels() {
    if (!kDebugMode) {
      return;
    }
    _debugActiveChannelsCount += 1;
    _logDebugResourceCounts();
  }

  void _decrementDebugChannels() {
    if (!kDebugMode) {
      return;
    }
    if (_debugActiveChannelsCount > 0) {
      _debugActiveChannelsCount -= 1;
    }
    _logDebugResourceCounts();
  }

  void _incrementDebugListeners() {
    if (!kDebugMode) {
      return;
    }
    _debugActiveListenersCount += 1;
    _logDebugResourceCounts();
  }

  void _decrementDebugListeners() {
    if (!kDebugMode) {
      return;
    }
    if (_debugActiveListenersCount > 0) {
      _debugActiveListenersCount -= 1;
    }
    _logDebugResourceCounts();
  }

  void _incrementDebugTimers() {
    if (!kDebugMode) {
      return;
    }
    _debugActiveTimersCount += 1;
    _logDebugResourceCounts();
  }

  void _decrementDebugTimers() {
    if (!kDebugMode) {
      return;
    }
    if (_debugActiveTimersCount > 0) {
      _debugActiveTimersCount -= 1;
    }
    _logDebugResourceCounts();
  }

  void _logDebugResourceCounts() {
    if (!kDebugMode) {
      return;
    }
    StabilityLogger.realtime(
      'Active Channels Count=$_debugActiveChannelsCount '
      'Active Listeners Count=$_debugActiveListenersCount '
      'Active Timers Count=$_debugActiveTimersCount',
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
