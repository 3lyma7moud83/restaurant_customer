import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/error_logger.dart';

class StabilityMetricsService {
  StabilityMetricsService._();

  static final StabilityMetricsService instance = StabilityMetricsService._();

  final Map<String, int> _counters = <String, int>{};
  final List<Map<String, dynamic>> _buffer = <Map<String, dynamic>>[];
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

  Map<String, int> snapshot() => Map<String, int>.from(_counters);

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
    final tableMissing = message.contains('public.customer_stability_metrics') &&
        (message.contains('could not find the table') ||
            message.contains('does not exist') ||
            message.contains('schema cache'));
    return code == 'PGRST205' || code == '42P01' || tableMissing;
  }
}
