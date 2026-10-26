import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:restaurant_customer/core/cache/local_reference_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DateTime now;
  late LocalReferenceCache cache;
  var calls = 0;
  var user = 'a';
  Future<List<Map<String, dynamic>>> load() async => [
        {'value': ++calls}
      ];
  Future<List<Map<String, dynamic>>> read(
          {String key = 'catalog:0:80',
          String scope = 'a',
          bool force = false,
          Future<List<Map<String, dynamic>>> Function()? loader}) =>
      cache.read(
          scope: scope,
          key: key,
          ttl: const Duration(minutes: 5),
          forceRefresh: force,
          load: loader ?? load,
          isCurrent: () => user == scope);
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    now = DateTime.utc(2026, 10, 22);
    cache = LocalReferenceCache('test', clock: () => now);
    calls = 0;
    user = 'a';
  });
  test('cold saves; new instance uses disk; copies cannot corrupt cache',
      () async {
    final first = await read();
    first.first['value'] = 999;
    cache = LocalReferenceCache('test', clock: () => now);
    expect((await read()).first['value'], 1);
    expect(calls, 1);
    expect(cache.hits, 1);
  });
  test('expiry and clock rollback require a new server read', () async {
    await read();
    now = now.add(const Duration(minutes: 5));
    expect((await read()).first['value'], 2);
    now = now.subtract(const Duration(days: 1));
    expect((await read()).first['value'], 3);
  });
  test('concurrent identical reads share network; other pages do not',
      () async {
    await Future.wait(List.generate(8, (_) => read()));
    expect(calls, 1);
    expect(cache.joinedReads, 7);
    await read(key: 'catalog:1:80');
    expect(calls, 2);
  });
  test('account and tenant keys remain isolated', () async {
    await read();
    user = 'b';
    await read(scope: 'b');
    expect(calls, 2);
    await read(scope: 'b', key: 'other-restaurant:0:80');
    expect(calls, 3);
  });
  test('account switch rejects an in-flight response', () async {
    final gate = Completer<List<Map<String, dynamic>>>();
    final started = Completer<void>();
    final result = read(loader: () {
      started.complete();
      return gate.future;
    });
    await started.future;
    user = 'b';
    final check = expectLater(result, throwsStateError);
    gate.complete([
      {'value': 'private'}
    ]);
    await check;
    expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
  });
  test('invalidation rejects older response and keeps newer disk data',
      () async {
    final gate = Completer<List<Map<String, dynamic>>>();
    final started = Completer<void>();
    final old = read(loader: () {
      started.complete();
      return gate.future;
    });
    await started.future;
    final check = expectLater(old, throwsStateError);
    await cache.invalidate('a', 'catalog:0:80');
    await read();
    gate.complete([
      {'value': 999}
    ]);
    await check;
    expect((await read()).first['value'], 1);
  });
  test('force refresh bypasses stored rows', () async {
    await read();
    expect((await read(force: true)).first['value'], 2);
  });
  test('concurrent forced refreshes share one request', () async {
    await read();
    final results =
        await Future.wait(List.generate(5, (_) => read(force: true)));
    expect(results.every((row) => row.first['value'] == 2), isTrue);
    expect(calls, 2);
  });
  test('network failure does not become successful cached data or retry loop',
      () async {
    await read();
    now = now.add(const Duration(hours: 1));
    var failedCalls = 0;
    await expectLater(read(loader: () async {
      failedCalls++;
      throw StateError('offline');
    }), throwsStateError);
    expect(failedCalls, 1);
    expect((await read()).first['value'], 2);
  });
  test('corrupt local data falls back to server', () async {
    await read();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(prefs.getKeys().single, 'invalid');
    expect((await read()).first['value'], 2);
  });
  test('bounded storage and measured repeated-read comparison', () async {
    for (var i = 0; i < 45; i++) {
      await read(key: 'row:$i');
    }
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys().length, LocalReferenceCache.maxEntries);
    SharedPreferences.setMockInitialValues({});
    calls = 0;
    cache = LocalReferenceCache('test', clock: () => now);
    for (var i = 0; i < 10; i++) {
      await read();
    }
    expect(calls, 1);
    expect(cache.hits, 9);
    final store = await SharedPreferences.getInstance();
    final bytes = store.getKeys().fold<int>(
        0, (sum, key) => sum + utf8.encode(store.getString(key)!).length);
    // Synthetic request counts only; no production traffic or latency claim.
    // ignore: avoid_print
    print(
        'CACHE_BENCH baseline_uncached=10 network=$calls hits=${cache.hits} avoided=9 payload_bytes=$bytes');
  });
}
