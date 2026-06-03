import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/error_logger.dart';
import 'stability_logger.dart';
import 'stability_metrics_service.dart';

typedef OfflineOrderSubmitter = Future<String> Function(
  Map<String, dynamic> payload,
);

class OfflineOrderQueueResult {
  const OfflineOrderQueueResult({
    required this.orderRequestToken,
    required this.orderId,
  });

  final String orderRequestToken;
  final String orderId;
}

class OfflineOrderQueueService {
  OfflineOrderQueueService._();

  static final OfflineOrderQueueService instance = OfflineOrderQueueService._();

  static const String _storageKey = 'offline_order_queue.v1';
  static const Duration _baseRetryDelay = Duration(seconds: 2);
  static const Duration _maxRetryDelay = Duration(minutes: 5);

  final List<Map<String, dynamic>> _queue = <Map<String, dynamic>>[];
  final StreamController<OfflineOrderQueueResult> _resultStreamController =
      StreamController<OfflineOrderQueueResult>.broadcast();
  final Connectivity _connectivity = Connectivity();

  SharedPreferences? _prefs;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  Timer? _flushTimer;
  OfflineOrderSubmitter? _submitter;
  bool _initialized = false;
  bool _flushInFlight = false;

  Stream<OfflineOrderQueueResult> get onSynced => _resultStreamController.stream;

  Future<void> initialize({
    required OfflineOrderSubmitter submitter,
  }) async {
    if (_initialized) {
      _submitter = submitter;
      return;
    }
    _initialized = true;
    _submitter = submitter;
    await StabilityMetricsService.instance.initialize();
    _prefs = await SharedPreferences.getInstance();
    await _restore();

    _connectivitySubscription = _connectivity.onConnectivityChanged.listen(
      (results) {
        if (results.contains(ConnectivityResult.none)) {
          return;
        }
        unawaited(flush());
      },
      onError: (_) {},
    );
    _flushTimer = Timer.periodic(
      const Duration(seconds: 20),
      (_) => unawaited(flush()),
    );
    unawaited(flush());
  }

  Future<void> enqueue(Map<String, dynamic> payload) async {
    if (!_initialized) {
      final submitter = _submitter;
      if (submitter != null) {
        await initialize(submitter: submitter);
      }
    }

    final token = payload['order_request_token']?.toString().trim() ?? '';
    if (token.isEmpty) {
      return;
    }
    final duplicate = _queue.any(
      (item) => item['order_request_token']?.toString().trim() == token,
    );
    if (duplicate) {
      return;
    }

    final now = DateTime.now().toUtc().toIso8601String();
    _queue.add({
      ...payload,
      'created_at': payload['created_at'] ?? now,
      'updated_at': now,
      'attempts': (payload['attempts'] as int? ?? 0),
      'status': 'pending',
      'next_retry_at': now,
    });
    await _persist();
    StabilityMetricsService.instance.increment(
      'offline_queue_enqueued',
      module: 'offline_order_queue',
    );
    StabilityLogger.offlineQueue('Enqueued order token=$token');
  }

  Future<void> flush() async {
    if (_flushInFlight || _queue.isEmpty) {
      return;
    }
    final submitter = _submitter;
    if (submitter == null) {
      return;
    }

    _flushInFlight = true;
    try {
      while (_queue.isNotEmpty) {
        final current = _queue.first;
        final token = current['order_request_token']?.toString().trim() ?? '';
        final now = DateTime.now().toUtc();
        final nextRetryAt = DateTime.tryParse(
          current['next_retry_at']?.toString() ?? '',
        )?.toUtc();
        if (nextRetryAt != null && now.isBefore(nextRetryAt)) {
          break;
        }

        try {
          final orderId = await submitter(Map<String, dynamic>.from(current));
          _queue.removeAt(0);
          await _persist();
          StabilityMetricsService.instance.increment(
            'offline_queue_synced',
            module: 'offline_order_queue',
          );
          StabilityLogger.offlineQueue('Synced queued order token=$token orderId=$orderId');
          _resultStreamController.add(
            OfflineOrderQueueResult(
              orderRequestToken: token,
              orderId: orderId,
            ),
          );
        } catch (error, stack) {
          final attempts = (current['attempts'] as int? ?? 0) + 1;
          current['attempts'] = attempts;
          final retryDelay = _retryDelayForAttempt(attempts);
          current['status'] = attempts >= 12 ? 'manual_review' : 'retry';
          current['updated_at'] = now.toIso8601String();
          current['next_retry_at'] = now.add(retryDelay).toIso8601String();
          if (attempts >= 12) {
            StabilityMetricsService.instance.increment(
              'offline_queue_manual_review',
              module: 'offline_order_queue',
            );
            StabilityLogger.offlineQueue(
              'Queued order token=$token requires manual review after $attempts attempts.',
            );
          } else {
            StabilityMetricsService.instance.increment(
              'offline_queue_retry_failures',
              module: 'offline_order_queue',
              payload: {'attempts': attempts},
            );
            StabilityLogger.offlineQueue(
              'Retry scheduled token=$token attempts=$attempts next=${current['next_retry_at']}',
            );
          }
          await ErrorLogger.logError(
            module: 'offline_order_queue_service.flush.submit',
            error: error,
            stack: stack,
          );
          if (_queue.length > 1) {
            // Preserve all queued orders and allow subsequent jobs to progress
            // when one entry is temporarily blocked.
            _queue
              ..removeAt(0)
              ..add(current);
          }
          break;
        }
      }
      await _persist();
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'offline_order_queue_service.flush',
        error: error,
        stack: stack,
      );
    } finally {
      _flushInFlight = false;
    }
  }

  Future<void> _restore() async {
    final raw = _prefs?.getString(_storageKey);
    if (raw == null || raw.trim().isEmpty) {
      return;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        return;
      }
      final seenTokens = <String>{};
      _queue
        ..clear()
        ..addAll(
          decoded.whereType<Map>().map((item) {
            final row = Map<String, dynamic>.from(item);
            final token = row['order_request_token']?.toString().trim() ?? '';
            if (token.isEmpty || !seenTokens.add(token)) {
              return const <String, dynamic>{};
            }
            row['attempts'] = _toInt(row['attempts']) ?? 0;
            row['status'] = row['status']?.toString() ?? 'pending';
            row['next_retry_at'] ??=
                DateTime.now().toUtc().toIso8601String();
            return row;
          }).where((item) => item.isNotEmpty),
        );
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'offline_order_queue_service.restore',
        error: error,
        stack: stack,
      );
    }
  }

  Future<void> _persist() async {
    final prefs = _prefs;
    if (prefs == null) {
      return;
    }
    await prefs.setString(
      _storageKey,
      jsonEncode(_queue),
    );
  }

  Duration _retryDelayForAttempt(int attempts) {
    final exponent = attempts.clamp(1, 8);
    final seconds = _baseRetryDelay.inSeconds * (1 << (exponent - 1));
    final bounded = seconds.clamp(
      _baseRetryDelay.inSeconds,
      _maxRetryDelay.inSeconds,
    );
    return Duration(seconds: bounded);
  }

  int? _toInt(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse(value?.toString() ?? '');
  }

  Future<void> dispose() async {
    await _connectivitySubscription?.cancel();
    _connectivitySubscription = null;
    _flushTimer?.cancel();
    _flushTimer = null;
  }
}
