import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/error_logger.dart';
import 'stability_logger.dart';
import 'stability_metrics_service.dart';

class AnalyticsIntegrityService {
  AnalyticsIntegrityService._();

  static final AnalyticsIntegrityService instance = AnalyticsIntegrityService._();

  static const String _storageKey = 'analytics_integrity_queue.v1';
  static const Duration _dedupeWindow = Duration(seconds: 15);

  SharedPreferences? _prefs;
  final Map<String, DateTime> _recentEventFingerprints = <String, DateTime>{};
  final List<Map<String, dynamic>> _queue = <Map<String, dynamic>>[];
  bool _initialized = false;
  bool _flushInFlight = false;
  Timer? _flushTimer;

  Future<void> initialize() async {
    if (_initialized) {
      return;
    }
    _initialized = true;
    await StabilityMetricsService.instance.initialize();
    _prefs = await SharedPreferences.getInstance();
    await _restoreQueue();
    _flushTimer = Timer.periodic(const Duration(seconds: 25), (_) {
      unawaited(flush());
    });
  }

  Future<void> trackEvent({
    required String eventName,
    required Map<String, dynamic> payload,
    String? userId,
  }) async {
    await initialize();

    final fingerprint = _fingerprint(
      eventName: eventName,
      userId: userId,
      payload: payload,
    );

    final now = DateTime.now().toUtc();
    _recentEventFingerprints.removeWhere(
      (_, at) => now.difference(at) > _dedupeWindow * 8,
    );
    final seenAt = _recentEventFingerprints[fingerprint];
    if (seenAt != null && now.difference(seenAt) <= _dedupeWindow) {
      StabilityMetricsService.instance.increment(
        'duplicate_analytics_events',
        module: 'analytics_integrity',
      );
      StabilityLogger.analytics(
        'Skipped duplicate analytics event name=$eventName fp=$fingerprint',
      );
      return;
    }
    _recentEventFingerprints[fingerprint] = now;

    final eventPayload = <String, dynamic>{
      'user_id': userId,
      'event_name': eventName,
      'event_fingerprint': fingerprint,
      'payload': payload,
      'status': 'pending',
      'attempts': 0,
      'created_at': now.toIso8601String(),
      'updated_at': now.toIso8601String(),
      'next_retry_at': now.toIso8601String(),
    };
    _queue.add(eventPayload);
    await _persistQueue();
    StabilityLogger.analytics('Queued analytics event name=$eventName');
    unawaited(flush());
  }

  Future<void> flush() async {
    if (_flushInFlight || _queue.isEmpty) {
      return;
    }

    final client = _clientOrNull;
    if (client == null) {
      return;
    }

    _flushInFlight = true;
    try {
      while (_queue.isNotEmpty) {
        final event = _queue.first;
        final now = DateTime.now().toUtc();
        final nextRetryAt = DateTime.tryParse(
          event['next_retry_at']?.toString() ?? '',
        )?.toUtc();
        if (nextRetryAt != null && now.isBefore(nextRetryAt)) {
          break;
        }
        try {
          await client.from('analytics_events_integrity').upsert(
            {
              ...event,
              'status': 'sent',
              'sent_at': DateTime.now().toUtc().toIso8601String(),
              'updated_at': DateTime.now().toUtc().toIso8601String(),
            },
            onConflict: 'user_id,event_fingerprint',
          );
          _queue.removeAt(0);
          StabilityMetricsService.instance.increment(
            'analytics_sent',
            module: 'analytics_integrity',
          );
        } catch (_) {
          final nextAttempts = (event['attempts'] as int? ?? 0) + 1;
          event['attempts'] = nextAttempts;
          event['updated_at'] = now.toIso8601String();
          if (nextAttempts > 20) {
            event['status'] = 'manual_review';
            event['next_retry_at'] =
                now.add(const Duration(minutes: 30)).toIso8601String();
            StabilityMetricsService.instance.increment(
              'analytics_manual_review',
              module: 'analytics_integrity',
            );
            break;
          } else {
            final exponent =
                nextAttempts < 1 ? 1 : (nextAttempts > 8 ? 8 : nextAttempts);
            final delaySeconds = (1 << exponent).clamp(2, 600).toInt();
            event['status'] = 'retry';
            event['next_retry_at'] =
                now.add(Duration(seconds: delaySeconds)).toIso8601String();
            StabilityMetricsService.instance.increment(
              'analytics_failed',
              module: 'analytics_integrity',
            );
          }
          break;
        }
      }
      await _persistQueue();
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'analytics_integrity_service.flush',
        error: error,
        stack: stack,
      );
    } finally {
      _flushInFlight = false;
    }
  }

  Future<void> dispose() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    await flush();
  }

  Future<void> _restoreQueue() async {
    final raw = _prefs?.getString(_storageKey);
    if (raw == null || raw.trim().isEmpty) {
      return;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        return;
      }
      _queue
        ..clear()
        ..addAll(
          decoded.whereType<Map>().map(
                (item) => Map<String, dynamic>.from(item),
              ),
        );
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'analytics_integrity_service.restore_queue',
        error: error,
        stack: stack,
      );
    }
  }

  Future<void> _persistQueue() async {
    final prefs = _prefs;
    if (prefs == null) {
      return;
    }
    await prefs.setString(_storageKey, jsonEncode(_queue));
  }

  String _fingerprint({
    required String eventName,
    required String? userId,
    required Map<String, dynamic> payload,
  }) {
    final normalizedPayload = Map<String, dynamic>.from(payload);
    final sortedKeys = normalizedPayload.keys.toList(growable: false)..sort();
    final joined = sortedKeys
        .map((key) => '$key=${normalizedPayload[key]}')
        .join('&');
    final input = '${userId ?? 'guest'}|$eventName|$joined';
    return sha256.convert(utf8.encode(input)).toString();
  }

  SupabaseClient? get _clientOrNull {
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }
}
