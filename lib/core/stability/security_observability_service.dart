import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/error_logger.dart';
import 'security_event_service.dart';
import 'stability_logger.dart';
import 'stability_metrics_service.dart';

class SecurityObservabilityService {
  SecurityObservabilityService._();

  static final SecurityObservabilityService instance =
      SecurityObservabilityService._();

  final Map<String, int> _localCounters = <String, int>{};
  Map<String, dynamic> _remoteSnapshot = <String, dynamic>{};
  Timer? _refreshTimer;
  bool _initialized = false;
  bool _refreshInFlight = false;
  bool _remoteDisabled = false;
  String? _remoteDisabledReason;

  Future<void> initialize() async {
    if (_initialized) {
      return;
    }
    _initialized = true;
    await StabilityMetricsService.instance.initialize();
    await SecurityEventService.instance.initialize();
    _refreshTimer = Timer.periodic(const Duration(seconds: 45), (_) {
      unawaited(refreshRemoteSnapshot());
    });
  }

  void incrementLocal(
    String key, {
    int delta = 1,
    Map<String, dynamic>? payload,
  }) {
    final normalizedKey = key.trim();
    if (normalizedKey.isEmpty) {
      return;
    }
    _localCounters.update(normalizedKey, (value) => value + delta,
        ifAbsent: () => delta);

    StabilityMetricsService.instance.increment(
      normalizedKey,
      delta: delta,
      module: 'security_observability',
      payload: payload,
    );
  }

  Future<void> refreshRemoteSnapshot({
    Duration lookback = const Duration(hours: 24),
  }) async {
    if (_remoteDisabled || _refreshInFlight) {
      return;
    }

    final client = _clientOrNull;
    if (client == null || client.auth.currentSession == null) {
      return;
    }

    _refreshInFlight = true;
    try {
      final interval = _toSqlInterval(lookback);
      final dynamic response = await client.rpc(
        'security_observability_dashboard',
        params: {
          'p_lookback': interval,
        },
      );
      if (response is Map) {
        _remoteSnapshot = Map<String, dynamic>.from(response);
      }
    } catch (error, stack) {
      if (_isMissingDashboardFunction(error)) {
        _remoteDisabled = true;
        _remoteDisabledReason = 'missing_function_security_observability_dashboard';
        await ErrorLogger.logError(
          module: 'security_observability_service.refresh_remote_snapshot',
          action: 'remote_disabled_$_remoteDisabledReason',
          error: error,
          stack: stack,
        );
        return;
      }
      await ErrorLogger.logError(
        module: 'security_observability_service.refresh_remote_snapshot',
        error: error,
        stack: stack,
      );
      StabilityLogger.security(
        '[AUTH_REVALIDATION] remote security dashboard refresh failed.',
      );
    } finally {
      _refreshInFlight = false;
    }
  }

  Future<Map<String, dynamic>> snapshot() async {
    await initialize();
    return {
      'generated_at': DateTime.now().toUtc().toIso8601String(),
      'local_counters': Map<String, int>.from(_localCounters),
      'recent_security_events': SecurityEventService.instance.recentCounts(),
      'remote_dashboard': Map<String, dynamic>.from(_remoteSnapshot),
    };
  }

  Future<void> dispose() async {
    _refreshTimer?.cancel();
    _refreshTimer = null;
    await SecurityEventService.instance.dispose();
  }

  String _toSqlInterval(Duration duration) {
    if (duration.inHours >= 1) {
      return '${duration.inHours} hours';
    }
    final minutes = duration.inMinutes <= 0 ? 1 : duration.inMinutes;
    return '$minutes minutes';
  }

  SupabaseClient? get _clientOrNull {
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }

  bool _isMissingDashboardFunction(Object error) {
    final message = error.toString().toLowerCase();
    final code = error is PostgrestException
        ? (error.code ?? '').trim().toUpperCase()
        : '';
    final functionMissing =
        message.contains('public.security_observability_dashboard') &&
            (message.contains('could not find the function') ||
                message.contains('does not exist') ||
                message.contains('schema cache'));
    return code == 'PGRST202' || code == '42883' || functionMissing;
  }
}
