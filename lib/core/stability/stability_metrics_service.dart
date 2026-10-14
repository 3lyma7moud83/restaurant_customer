import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/error_logger.dart';

class SecurityEventMetricSample {
  const SecurityEventMetricSample({
    required this.eventKey,
    required this.severity,
    required this.value,
  });

  final String eventKey;
  final String severity;
  final int value;
}

@visibleForTesting
List<SecurityEventMetricSample> aggregateSecurityEventMetricSamples(
  Iterable<SecurityEventMetricSample> samples,
) {
  final aggregated = <String, SecurityEventMetricSample>{};
  for (final sample in samples) {
    final key = '${sample.eventKey}\u0000${sample.severity}';
    final existing = aggregated[key];
    aggregated[key] = SecurityEventMetricSample(
      eventKey: sample.eventKey,
      severity: sample.severity,
      value: sample.value + (existing?.value ?? 0),
    );
  }
  return aggregated.values.toList(growable: false);
}

class StabilityMetricsService {
  StabilityMetricsService._();

  static final StabilityMetricsService instance = StabilityMetricsService._();

  final Map<String, int> _counters = <String, int>{};
  final List<Map<String, dynamic>> _buffer = <Map<String, dynamic>>[];
  final Map<String, SecurityEventMetricSample> _securityEventMetrics =
      <String, SecurityEventMetricSample>{};
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
    _flushTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      unawaited(flush());
    });
  }

  Future<void> dispose() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    await flush();
  }

  void increment(
    String key, {
    int delta = 1,
    String? module,
    Map<String, dynamic>? payload,
  }) {
    final value = _counters[key] ?? 0;
    _counters[key] = value + delta;
    if (_remoteDisabled) {
      return;
    }
    _buffer.add({
      'metric_key': key,
      'metric_value': delta,
      'module': module ?? 'stability',
      'payload': payload ?? const <String, dynamic>{},
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
    if (_buffer.length > 1500) {
      _buffer.removeRange(0, _buffer.length - 1500);
    }
    if (_buffer.length >= 50) {
      unawaited(flush());
    }
  }

  int valueOf(String key) => _counters[key] ?? 0;

  /// Aggregates the redundant metric emitted beside every detailed event.
  /// Detailed security events remain in [SecurityEventService].
  void incrementSecurityEventsBuffered({
    required String eventKey,
    required String severity,
  }) {
    final normalizedEventKey = eventKey.trim();
    final normalizedSeverity =
        severity.trim().isEmpty ? 'medium' : severity.trim();
    if (normalizedEventKey.isEmpty || _remoteDisabled) {
      return;
    }

    _counters.update(
      'security_events_buffered',
      (value) => value + 1,
      ifAbsent: () => 1,
    );
    final sample = SecurityEventMetricSample(
      eventKey: normalizedEventKey,
      severity: normalizedSeverity,
      value: 1,
    );
    final key = '$normalizedEventKey\u0000$normalizedSeverity';
    _securityEventMetrics[key] = aggregateSecurityEventMetricSamples([
      if (_securityEventMetrics[key] case final existing?) existing,
      sample,
    ]).single;
  }

  Map<String, int> snapshot() => Map<String, int>.from(_counters);

  Future<void> flush() async {
    if (_remoteDisabled || _flushInFlight) {
      return;
    }

    _drainSecurityEventMetrics();
    if (_buffer.isEmpty) {
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
        await client.from('customer_stability_metrics').insert(batch);
      } catch (error, stack) {
        if (_isMissingRemoteSchema(error)) {
          _remoteDisabled = true;
          _remoteDisabledReason = 'missing_table_customer_stability_metrics';
          await ErrorLogger.logError(
            module: 'stability_metrics_service.flush',
            action: 'remote_disabled_$_remoteDisabledReason',
            error: error,
            stack: stack,
          );
          return;
        }
        _buffer.insertAll(0, batch);
        if (_buffer.length > 1500) {
          _buffer.removeRange(1500, _buffer.length);
        }
        await ErrorLogger.logError(
          module: 'stability_metrics_service.flush',
          error: error,
          stack: stack,
        );
      }
    } finally {
      _flushInFlight = false;
    }
  }

  void _drainSecurityEventMetrics() {
    if (_securityEventMetrics.isEmpty) {
      return;
    }
    final now = DateTime.now().toUtc().toIso8601String();
    for (final sample in _securityEventMetrics.values) {
      _buffer.add({
        'metric_key': 'security_events_buffered',
        'metric_value': sample.value,
        'module': 'security_event_service',
        'payload': {
          'event_key': sample.eventKey,
          'severity': sample.severity,
        },
        'created_at': now,
      });
    }
    _securityEventMetrics.clear();
    if (_buffer.length > 1500) {
      _buffer.removeRange(0, _buffer.length - 1500);
    }
  }

  SupabaseClient? get _clientOrNull {
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }

  bool _isMissingRemoteSchema(Object error) {
    final message = error.toString().toLowerCase();
    final code = error is PostgrestException
        ? (error.code ?? '').trim().toUpperCase()
        : '';
    final tableMissing =
        message.contains('public.customer_stability_metrics') &&
            (message.contains('could not find the table') ||
                message.contains('does not exist') ||
                message.contains('schema cache'));
    return code == 'PGRST205' || code == '42P01' || tableMissing;
  }
}
