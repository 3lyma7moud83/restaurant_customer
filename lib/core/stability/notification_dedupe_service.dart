import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/error_logger.dart';
import 'stability_logger.dart';
import 'stability_metrics_service.dart';

class NotificationDedupeService {
  NotificationDedupeService._();

  static final NotificationDedupeService instance =
      NotificationDedupeService._();

  static const String _storageKey = 'notification_dedupe_cache.v1';
  static const Duration _cacheRetention = Duration(hours: 6);

  SharedPreferences? _prefs;
  final Map<String, DateTime> _recent = <String, DateTime>{};
  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) {
      return;
    }
    _initialized = true;
    await StabilityMetricsService.instance.initialize();
    _prefs = await SharedPreferences.getInstance();
    await _restore();
  }

  Future<bool> shouldProcess({
    required String fingerprint,
    required String source,
    String? userId,
    Duration dedupeWindow = const Duration(seconds: 10),
  }) async {
    await initialize();

    final now = DateTime.now().toUtc();
    _recent.removeWhere((_, at) => now.difference(at) > _cacheRetention);
    final key = '${userId ?? 'guest'}|$source|$fingerprint';
    final seenAt = _recent[key];
    if (seenAt != null && now.difference(seenAt) <= dedupeWindow) {
      StabilityMetricsService.instance.increment(
        'notification_duplicates',
        module: 'notification_dedupe',
      );
      StabilityLogger.notification('Duplicate notification skipped key=$key');
      return false;
    }

    _recent[key] = now;
    unawaited(_persist());
    unawaited(_upsertRemoteFingerprint(
      userId: userId,
      source: source,
      fingerprint: fingerprint,
    ));
    return true;
  }

  Future<void> _upsertRemoteFingerprint({
    required String? userId,
    required String source,
    required String fingerprint,
  }) async {
    if (userId == null || userId.trim().isEmpty) {
      return;
    }

    final client = _clientOrNull;
    if (client == null) {
      return;
    }

    try {
      final existing = await client
          .from('notification_fingerprints')
          .select('id, occurrences')
          .eq('user_id', userId)
          .eq('source', source)
          .eq('fingerprint', fingerprint)
          .limit(1)
          .maybeSingle();

      if (existing is Map<String, dynamic>) {
        final id = existing['id'];
        final occurrences = _toInt(existing['occurrences']) ?? 1;
        await client.from('notification_fingerprints').update({
          'occurrences': occurrences + 1,
          'last_seen_at': DateTime.now().toUtc().toIso8601String(),
        }).eq('id', id);
        return;
      }

      await client.from('notification_fingerprints').insert({
        'user_id': userId,
        'source': source,
        'fingerprint': fingerprint,
        'occurrences': 1,
      });
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'notification_dedupe_service.upsert_remote',
        error: error,
        stack: stack,
      );
    }
  }

  Future<void> _restore() async {
    final raw = _prefs?.getString(_storageKey);
    if (raw == null || raw.trim().isEmpty) {
      return;
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return;
      }
      final entries = decoded['entries'];
      if (entries is! List) {
        return;
      }

      final now = DateTime.now().toUtc();
      for (final item in entries) {
        if (item is! Map) {
          continue;
        }
        final key = item['key']?.toString();
        final at = DateTime.tryParse(item['at']?.toString() ?? '')?.toUtc();
        if (key == null || at == null) {
          continue;
        }
        if (now.difference(at) > _cacheRetention) {
          continue;
        }
        _recent[key] = at;
      }
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'notification_dedupe_service.restore',
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
    final payload = {
      'entries': _recent.entries
          .map((entry) => {
                'key': entry.key,
                'at': entry.value.toUtc().toIso8601String(),
              })
          .toList(growable: false),
    };
    await prefs.setString(_storageKey, jsonEncode(payload));
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

  SupabaseClient? get _clientOrNull {
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }
}
