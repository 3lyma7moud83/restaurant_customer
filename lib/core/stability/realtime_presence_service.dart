import 'dart:async';
import 'dart:math';

import '../services/error_logger.dart';
import 'stability_logger.dart';
import 'stability_metrics_service.dart';

class RealtimePresenceService {
  RealtimePresenceService._();

  static final RealtimePresenceService instance = RealtimePresenceService._();

  static const Duration _staleEntryTtl = Duration(minutes: 10);
  static const Duration _cleanupInterval = Duration(seconds: 45);
  static const List<Duration> _reconnectBackoff = <Duration>[
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 10),
    Duration(seconds: 30),
  ];

  final Map<String, _RealtimePresenceEntry> _entries =
      <String, _RealtimePresenceEntry>{};
  final Random _random = Random();
  Timer? _cleanupTimer;
  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) {
      return;
    }
    _initialized = true;
    await StabilityMetricsService.instance.initialize();
    _cleanupTimer = Timer.periodic(_cleanupInterval, (_) {
      unawaited(_cleanupStaleEntries());
    });
  }

  void register(String topic) {
    unawaited(initialize());
    final now = DateTime.now().toUtc();
    final current = _entries[topic];
    if (current != null) {
      current.subscriptionCount += 1;
      current.lastSeenAt = now;
      if (current.subscriptionCount > 1) {
        StabilityMetricsService.instance.increment(
          'duplicate_realtime_subscriptions',
          module: 'realtime_presence',
          payload: {'topic': topic},
        );
        StabilityLogger.realtime(
          'Duplicate realtime listener detected topic=$topic count=${current.subscriptionCount}',
        );
      }
      return;
    }

    _entries[topic] = _RealtimePresenceEntry(
      lastSeenAt: now,
      lastReconnectAt: now,
      subscriptionCount: 1,
      reconnectAttempts: 0,
    );
  }

  void unregister(String topic) {
    final entry = _entries[topic];
    if (entry == null) {
      return;
    }
    entry.subscriptionCount -= 1;
    if (entry.subscriptionCount <= 0) {
      _entries.remove(topic);
    }
  }

  void markHeartbeat(String topic) {
    final now = DateTime.now().toUtc();
    final entry = _entries[topic];
    if (entry == null) {
      _entries[topic] = _RealtimePresenceEntry(
        lastSeenAt: now,
        lastReconnectAt: now,
        subscriptionCount: 1,
        reconnectAttempts: 0,
      );
      return;
    }
    entry.lastSeenAt = now;
  }

  void markReconnectScheduled(String topic) {
    final now = DateTime.now().toUtc();
    final entry = _entries.putIfAbsent(
      topic,
      () => _RealtimePresenceEntry(
        lastSeenAt: now,
        lastReconnectAt: now,
        subscriptionCount: 1,
        reconnectAttempts: 0,
      ),
    );
    entry.reconnectAttempts += 1;
    entry.lastReconnectAt = now;
    if (entry.reconnectAttempts >= 5) {
      StabilityMetricsService.instance.increment(
        'reconnect_failures',
        module: 'realtime_presence',
        payload: {'topic': topic, 'attempts': entry.reconnectAttempts},
      );
    }
  }

  void markReconnectSucceeded(String topic) {
    final now = DateTime.now().toUtc();
    final entry = _entries.putIfAbsent(
      topic,
      () => _RealtimePresenceEntry(
        lastSeenAt: now,
        lastReconnectAt: now,
        subscriptionCount: 1,
        reconnectAttempts: 0,
      ),
    );
    entry.reconnectAttempts = 0;
    entry.lastSeenAt = now;
    entry.lastReconnectAt = now;
  }

  bool isHeartbeatStale(
    String topic, {
    Duration staleAfter = const Duration(seconds: 90),
  }) {
    final entry = _entries[topic];
    if (entry == null) {
      return true;
    }
    return DateTime.now().toUtc().difference(entry.lastSeenAt) > staleAfter;
  }

  Duration reconnectDelay(String topic) {
    final entry = _entries[topic];
    final attempts = entry?.reconnectAttempts ?? 0;
    final index = attempts <= 0
        ? 0
        : (attempts - 1).clamp(0, _reconnectBackoff.length - 1);
    final baseDelay = _reconnectBackoff[index];
    final jitterMs = _random.nextInt(600);
    return baseDelay + Duration(milliseconds: jitterMs);
  }

  Future<void> _cleanupStaleEntries() async {
    try {
      final now = DateTime.now().toUtc();
      final staleTopics = _entries.entries
          .where((entry) =>
              now.difference(entry.value.lastSeenAt) > _staleEntryTtl)
          .map((entry) => entry.key)
          .toList(growable: false);
      if (staleTopics.isEmpty) {
        return;
      }

      for (final topic in staleTopics) {
        _entries.remove(topic);
      }
      StabilityMetricsService.instance.increment(
        'stale_realtime_subscriptions',
        delta: staleTopics.length,
        module: 'realtime_presence',
      );
      StabilityLogger.realtime(
        'Cleaned stale realtime subscriptions count=${staleTopics.length}',
      );
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'realtime_presence_service.cleanup',
        error: error,
        stack: stack,
      );
    }
  }

  Future<void> dispose() async {
    _cleanupTimer?.cancel();
    _cleanupTimer = null;
    _entries.clear();
  }
}

class _RealtimePresenceEntry {
  _RealtimePresenceEntry({
    required this.lastSeenAt,
    required this.lastReconnectAt,
    required this.subscriptionCount,
    required this.reconnectAttempts,
  });

  DateTime lastSeenAt;
  DateTime lastReconnectAt;
  int subscriptionCount;
  int reconnectAttempts;
}
