import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/error_logger.dart';
import 'stability_logger.dart';
import 'stability_metrics_service.dart';

class SecurityEventRecord {
  const SecurityEventRecord({
    required this.eventKey,
    required this.severity,
    required this.createdAt,
    required this.payload,
  });

  final String eventKey;
  final String severity;
  final DateTime createdAt;
  final Map<String, dynamic> payload;
}

class SecurityEventService {
  SecurityEventService._();

  static final SecurityEventService instance = SecurityEventService._();

  static const int _maxBufferedEvents = 600;
  static const int _maxRecentEvents = 240;
  static const Duration _flushInterval = Duration(seconds: 25);

  final List<Map<String, dynamic>> _buffer = <Map<String, dynamic>>[];
  final List<SecurityEventRecord> _recentEvents = <SecurityEventRecord>[];
  Timer? _flushTimer;
  bool _initialized = false;
  bool _flushInFlight = false;
  bool _remoteDisabled = false;
  String? _remoteDisabledReason;

  Future<void> initialize() async {
    if (_initialized) {
      return;
    }
    _initialized = true;
    await StabilityMetricsService.instance.initialize();
    _flushTimer = Timer.periodic(_flushInterval, (_) {
      unawaited(flush());
    });
  }

  void record({
    required String eventKey,
    String severity = 'medium',
    Map<String, dynamic>? payload,
    String? relatedRequestId,
    String? relatedNonce,
    String? sessionId,
    String? deviceFingerprint,
    bool flushNow = false,
  }) {
    final normalizedKey = eventKey.trim();
    if (normalizedKey.isEmpty) {
      return;
    }

    final now = DateTime.now().toUtc();
    final effectivePayload = Map<String, dynamic>.from(payload ?? const {});
    final userId = _currentUserId;

    _recentEvents.add(
      SecurityEventRecord(
        eventKey: normalizedKey,
        severity: severity.trim().isEmpty ? 'medium' : severity.trim(),
        createdAt: now,
        payload: effectivePayload,
      ),
    );
    if (_recentEvents.length > _maxRecentEvents) {
      _recentEvents.removeRange(0, _recentEvents.length - _maxRecentEvents);
    }

    if (!_remoteDisabled) {
      _buffer.add({
        'event_key': normalizedKey,
        'severity': severity.trim().isEmpty ? 'medium' : severity.trim(),
        'actor_user_id': userId,
        'session_id': sessionId,
        'device_fingerprint': deviceFingerprint,
        'event_payload': effectivePayload,
        'related_request_id': relatedRequestId,
        'related_nonce': relatedNonce,
        'occurred_at': now.toIso8601String(),
      });

      if (_buffer.length > _maxBufferedEvents) {
        _buffer.removeRange(0, _buffer.length - _maxBufferedEvents);
      }
    }

    StabilityLogger.security(
      '[SECURITY_EVENT] key=$normalizedKey severity=$severity payload=$effectivePayload',
    );
    StabilityMetricsService.instance.increment(
      'security_events_buffered',
      module: 'security_event_service',
      payload: {'event_key': normalizedKey, 'severity': severity},
    );

    if (flushNow || _buffer.length >= 40) {
      unawaited(flush());
    }
  }

  Map<String, int> recentCounts({
    Duration window = const Duration(minutes: 15),
  }) {
    final cutoff = DateTime.now().toUtc().subtract(window);
    final counts = <String, int>{};
    for (final event in _recentEvents) {
      if (event.createdAt.isBefore(cutoff)) {
        continue;
      }
      counts.update(event.eventKey, (value) => value + 1, ifAbsent: () => 1);
    }
    return counts;
  }

  Future<void> flush() async {
    if (_remoteDisabled || _flushInFlight || _buffer.isEmpty) {
      return;
    }

    final client = _clientOrNull;
    if (client == null || client.auth.currentSession == null) {
      return;
    }

    _flushInFlight = true;
    try {
      final batch = List<Map<String, dynamic>>.from(_buffer);
      _buffer.clear();
      try {
        await client.from('security_events').insert(batch);
        StabilityMetricsService.instance.increment(
          'security_events_flushed',
          delta: batch.length,
          module: 'security_event_service',
        );
      } catch (error, stack) {
        if (_isMissingSecurityEventsTable(error)) {
          _remoteDisabled = true;
          _remoteDisabledReason = 'missing_table_security_events';
          await ErrorLogger.logError(
            module: 'security_event_service.flush',
            action: 'remote_disabled_$_remoteDisabledReason',
            error: error,
            stack: stack,
          );
          return;
        }
        _buffer.insertAll(0, batch);
        if (_buffer.length > _maxBufferedEvents) {
          _buffer.removeRange(_maxBufferedEvents, _buffer.length);
        }
        await ErrorLogger.logError(
          module: 'security_event_service.flush',
          error: error,
          stack: stack,
        );
      }
    } finally {
      _flushInFlight = false;
    }
  }

  Future<void> dispose() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    await flush();
  }

  String? get _currentUserId => _clientOrNull?.auth.currentUser?.id;

  SupabaseClient? get _clientOrNull {
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }

  bool _isMissingSecurityEventsTable(Object error) {
    final message = error.toString().toLowerCase();
    final code = error is PostgrestException
        ? (error.code ?? '').trim().toUpperCase()
        : '';
    final tableMissing = message.contains('public.security_events') &&
        (message.contains('could not find the table') ||
            message.contains('does not exist') ||
            message.contains('schema cache'));
    return code == 'PGRST205' || code == '42P01' || tableMissing;
  }
}
