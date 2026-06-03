import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_error.dart';

class ErrorReporter {
  ErrorReporter();

  static const String _queueStorageKey = 'error_reporter.queue.v1';
  static const int _maxQueueSize = 300;

  final Connectivity _connectivity = Connectivity();
  final List<AppError> _queue = <AppError>[];

  SharedPreferences? _prefs;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  Timer? _flushTimer;
  bool _initialized = false;
  bool _flushInFlight = false;
  List<ConnectivityResult> _lastConnectivity = <ConnectivityResult>[
    ConnectivityResult.none,
  ];

  Future<void> initialize() async {
    if (_initialized) {
      return;
    }
    _initialized = true;

    try {
      _prefs = await SharedPreferences.getInstance();
      await _restoreQueue();
    } catch (_) {}

    try {
      _lastConnectivity = await _safeCheckConnectivity();
      _connectivitySubscription = _connectivity.onConnectivityChanged.listen(
        (results) {
          _lastConnectivity = results;
          if (_hasInternet(results)) {
            unawaited(flushQueue());
          }
        },
        onError: (_) {},
      );
    } catch (_) {}

    _flushTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      unawaited(flushQueue());
    });
  }

  Future<void> dispose() async {
    await _connectivitySubscription?.cancel();
    _connectivitySubscription = null;
    _flushTimer?.cancel();
    _flushTimer = null;
  }

  Future<String> resolveInternetStatus() async {
    final results = await _safeCheckConnectivity();
    _lastConnectivity = results;
    return _internetStatusFrom(results);
  }

  String get cachedInternetStatus => _internetStatusFrom(_lastConnectivity);

  Future<void> report(AppError error) async {
    try {
      if (!_initialized) {
        await initialize();
      }

      final currentStatus = await resolveInternetStatus();
      final enriched = error.copyWith(internetStatus: currentStatus);
      if (!_hasInternet(_lastConnectivity)) {
        await _enqueue(enriched);
        return;
      }

      final inserted = await _upsertRemote(enriched);
      if (!inserted) {
        await _enqueue(enriched);
        return;
      }

      if (_queue.isNotEmpty) {
        unawaited(flushQueue());
      }
    } catch (_) {
      await _enqueue(error);
    }
  }

  Future<void> flushQueue() async {
    try {
      if (_flushInFlight || _queue.isEmpty) {
        return;
      }

      if (!_hasInternet(await _safeCheckConnectivity())) {
        return;
      }

      _flushInFlight = true;
      while (_queue.isNotEmpty) {
        final current = _queue.first;
        final inserted = await _upsertRemote(current);
        if (!inserted) {
          break;
        }
        _queue.removeAt(0);
      }
      await _persistQueue();
    } finally {
      _flushInFlight = false;
    }
  }

  Future<void> _enqueue(AppError error) async {
    _queue.add(error);
    if (_queue.length > _maxQueueSize) {
      _queue.removeRange(0, _queue.length - _maxQueueSize);
    }
    await _persistQueue();
  }

  Future<void> _persistQueue() async {
    final prefs = _prefs;
    if (prefs == null) {
      return;
    }
    final values = _queue.map((e) => e.toJsonString()).toList(growable: false);
    await prefs.setStringList(_queueStorageKey, values);
  }

  Future<void> _restoreQueue() async {
    final prefs = _prefs;
    if (prefs == null) {
      return;
    }
    final values = prefs.getStringList(_queueStorageKey) ?? const <String>[];
    _queue
      ..clear()
      ..addAll(
        values
            .map(AppError.fromJsonString)
            .whereType<AppError>()
            .toList(growable: false),
      );
  }

  Future<bool> _upsertRemote(AppError error) async {
    final client = _clientOrNull;
    if (client == null) {
      return false;
    }

    try {
      final existing = await client
          .from('system_errors')
          .select('id, occurrences')
          .eq('app_name', error.appName)
          .eq('fingerprint', error.fingerprint)
          .limit(1)
          .maybeSingle();

      if (existing is Map<String, dynamic>) {
        final id = existing['id']?.toString();
        if (id != null && id.isNotEmpty) {
          final oldOccurrences = _toInt(existing['occurrences']) ?? 1;
          await client.from('system_errors').update({
            'occurrences': oldOccurrences + error.occurrences,
            'status': 'open',
            'is_resolved': false,
          }).eq('id', id);
          return true;
        }
      }

      await client.from('system_errors').insert(error.toSupabasePayload());
      return true;
    } catch (_) {
      return false;
    }
  }

  SupabaseClient? get _clientOrNull {
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }

  Future<List<ConnectivityResult>> _safeCheckConnectivity() async {
    try {
      return await _connectivity.checkConnectivity();
    } catch (_) {
      return _lastConnectivity;
    }
  }

  bool _hasInternet(List<ConnectivityResult> results) {
    if (results.isEmpty) {
      return false;
    }
    return !results.contains(ConnectivityResult.none);
  }

  String _internetStatusFrom(List<ConnectivityResult> results) {
    if (results.isEmpty || results.contains(ConnectivityResult.none)) {
      return 'offline';
    }
    return results.map((e) => e.name).join(',');
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
}
