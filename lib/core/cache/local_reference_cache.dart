import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// Display/reference rows only. Never use for access checks or transactions.
/// Expired data fails closed; callers explicitly refresh to observe mutations.
class LocalReferenceCache {
  LocalReferenceCache(this.namespace, {DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;
  final String namespace;
  final DateTime Function() _clock;
  final Map<String, Future<List<Map<String, dynamic>>>> _pending = {};
  final Map<String, Future<List<Map<String, dynamic>>>> _refreshes = {};
  final Map<String, int> _versions = {};
  Future<void> _writes = Future.value();
  int hits = 0, networkReads = 0, joinedReads = 0;
  static const maxEntries = 24;
  static const maxEntryBytes = 128 * 1024;

  String _key(String scope, String key) =>
      'reference_v1:$namespace:${jsonEncode([scope, key])}';
  List<Map<String, dynamic>> _copy(dynamic rows) =>
      (jsonDecode(jsonEncode(rows)) as List)
          .map((row) => Map<String, dynamic>.from(row as Map))
          .toList();

  Future<List<Map<String, dynamic>>> read({
    required String scope,
    required String key,
    required Duration ttl,
    required Future<List<Map<String, dynamic>>> Function() load,
    required bool Function() isCurrent,
    bool forceRefresh = false,
  }) async {
    if (!isCurrent()) throw StateError('Cache scope changed');
    final storageKey = _key(scope, key);
    // Explicit refresh invalidates before joining, so pre-mutation work cannot
    // satisfy a post-mutation read. Ordinary concurrent reads share one request.
    if (forceRefresh) {
      final existing = _refreshes[storageKey];
      if (existing != null) {
        joinedReads++;
        final rows = await existing;
        if (!isCurrent()) throw StateError('Cache scope changed');
        return _copy(rows);
      }
      final refresh = () async {
        await invalidate(scope, key);
        return read(
            scope: scope, key: key, ttl: ttl, load: load, isCurrent: isCurrent);
      }();
      _refreshes[storageKey] = refresh;
      try {
        return _copy(await refresh);
      } finally {
        if (identical(_refreshes[storageKey], refresh)) {
          _refreshes.remove(storageKey);
        }
      }
    }
    final active = _pending[storageKey];
    if (active != null) {
      final joinedVersion = _versions[storageKey] ?? 0;
      joinedReads++;
      final value = await active;
      if (!isCurrent() || (_versions[storageKey] ?? 0) != joinedVersion) {
        throw StateError('Cache read superseded');
      }
      return _copy(value);
    }
    final version = _versions[storageKey] ?? 0;
    bool valid() => isCurrent() && (_versions[storageKey] ?? 0) == version;
    final task = () async {
      SharedPreferences? prefs;
      try {
        prefs = await SharedPreferences.getInstance();
        final raw = prefs.getString(storageKey);
        if (raw != null && !forceRefresh) {
          final entry = jsonDecode(raw) as Map;
          final age = _clock().millisecondsSinceEpoch - (entry['at'] as int);
          if (age >= 0 && age < ttl.inMilliseconds && valid()) {
            final rows = _copy(entry['rows']);
            hits++;
            return rows;
          }
        }
      } catch (_) {
        /* A broken/quota-limited store must not break networking. */
      }
      if (!valid()) throw StateError('Cache read superseded');
      networkReads++;
      final rows = await load();
      if (!valid()) throw StateError('Cache read superseded');
      final encoded =
          jsonEncode({'at': _clock().millisecondsSinceEpoch, 'rows': rows});
      if (prefs != null && utf8.encode(encoded).length <= maxEntryBytes) {
        final store = prefs;
        await _write(() async {
          if (!valid()) return;
          await store.setString(storageKey, encoded);
          final entries = store
              .getKeys()
              .where((k) => k.startsWith('reference_v1:$namespace:'))
              .toList();
          entries.sort(
              (a, b) => _timestamp(store, a).compareTo(_timestamp(store, b)));
          for (final old in entries.take((entries.length - maxEntries)
              .clamp(0, maxEntries + entries.length))) {
            await store.remove(old);
          }
        });
      }
      if (!valid()) throw StateError('Cache read superseded');
      return _copy(rows);
    }();
    _pending[storageKey] = task;
    try {
      return _copy(await task);
    } finally {
      if (identical(_pending[storageKey], task)) _pending.remove(storageKey);
    }
  }

  int _timestamp(SharedPreferences prefs, String key) {
    try {
      return (jsonDecode(prefs.getString(key)!) as Map)['at'] as int;
    } catch (_) {
      return 0;
    }
  }

  Future<void> _write(Future<void> Function() action) {
    _writes = _writes.then((_) async {
      try {
        await action();
      } catch (_) {}
    });
    return _writes;
  }

  Future<void> invalidate(String scope, String key) {
    final storageKey = _key(scope, key);
    _versions[storageKey] = (_versions[storageKey] ?? 0) + 1;
    _pending.remove(storageKey);
    _refreshes.remove(storageKey);
    return _write(
        () async => (await SharedPreferences.getInstance()).remove(storageKey));
  }
}
