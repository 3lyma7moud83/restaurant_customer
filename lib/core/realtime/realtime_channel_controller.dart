import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/error_logger.dart';

typedef RealtimeChannelBuilder = RealtimeChannel Function(
  SupabaseClient client,
  String channelName,
);

typedef RealtimeSubscribedCallback = FutureOr<void> Function(
  bool didReconnect,
);

class RealtimeChannelController {
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
  Timer? _restartTimer;
  bool _disposed = false;
  bool _hasSubscribedOnce = false;

  void subscribe(
    RealtimeChannelBuilder builder, {
    bool resetConnectionState = false,
  }) {
    _builder = builder;
    if (resetConnectionState) {
      _hasSubscribedOnce = false;
    }
    _restartTimer?.cancel();
    unawaited(_replaceChannel());
  }

  Future<void> clear() async {
    _restartTimer?.cancel();
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
    _builder = null;
    await clear();
  }

  Future<void> _replaceChannel() async {
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

      final channelName =
          '$_topicPrefix-${DateTime.now().microsecondsSinceEpoch}';
      final channel = builder(_client, channelName);
      _channel = channel;

      channel.subscribe((status, [error]) {
        if (_disposed || !identical(_channel, channel)) {
          return;
        }

        switch (status) {
          case RealtimeSubscribeStatus.subscribed:
            _restartTimer?.cancel();
            final didReconnect = _hasSubscribedOnce;
            _hasSubscribedOnce = true;
            if (onSubscribed != null) {
              unawaited(_handleSubscribed(didReconnect));
            }
            break;
          case RealtimeSubscribeStatus.channelError:
          case RealtimeSubscribeStatus.timedOut:
            unawaited(
              ErrorLogger.logError(
                module: 'realtime_channel_controller.subscribe.$_topicPrefix',
                error: error ?? Exception('Realtime status: $status'),
              ),
            );
            _scheduleRestart();
            break;
          case RealtimeSubscribeStatus.closed:
            _scheduleRestart();
            break;
        }
      });
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'realtime_channel_controller.replace.$_topicPrefix',
        error: error,
        stack: stack,
      );
      _scheduleRestart();
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

  void _scheduleRestart() {
    if (_disposed || _builder == null) {
      return;
    }

    _restartTimer?.cancel();
    _restartTimer = Timer(const Duration(seconds: 3), () {
      if (_disposed || _builder == null) {
        return;
      }
      subscribe(_builder!);
    });
  }
}
