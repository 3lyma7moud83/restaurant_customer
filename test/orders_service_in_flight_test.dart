import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:restaurant_customer/services/orders_service.dart';

void main() {
  group('coalesceInFlightOrderRead', () {
    test('shares one in-flight read for identical requests', () async {
      final requests = <String, Future<int>>{};
      final completer = Completer<int>();
      var loads = 0;

      Future<int> load() {
        loads += 1;
        return completer.future;
      }

      final first = coalesceInFlightOrderRead(
        requests: requests,
        key: 'order-1|customer-1|forceRefresh:true',
        load: load,
      );
      final second = coalesceInFlightOrderRead(
        requests: requests,
        key: 'order-1|customer-1|forceRefresh:true',
        load: load,
      );

      expect(loads, 1);
      expect(identical(first, second), isTrue);

      completer.complete(7);
      await expectLater(first, completion(7));
      await Future<void>.delayed(Duration.zero);
      expect(requests, isEmpty);
    });

    test('does not merge requests with different freshness requirements',
        () async {
      final requests = <String, Future<int>>{};
      final first = Completer<int>();
      final second = Completer<int>();
      var loads = 0;

      final cachedRead = coalesceInFlightOrderRead(
        requests: requests,
        key: 'order-1|customer-1|forceRefresh:false',
        load: () {
          loads += 1;
          return first.future;
        },
      );
      final refreshedRead = coalesceInFlightOrderRead(
        requests: requests,
        key: 'order-1|customer-1|forceRefresh:true',
        load: () {
          loads += 1;
          return second.future;
        },
      );

      expect(loads, 2);
      first.complete(1);
      second.complete(2);
      await expectLater(cachedRead, completion(1));
      await expectLater(refreshedRead, completion(2));
    });

    test('releases a failed request so a later read can retry', () async {
      final requests = <String, Future<int>>{};
      final first = coalesceInFlightOrderRead(
        requests: requests,
        key: 'order-1|customer-1|forceRefresh:true',
        load: () => Future<int>.error(StateError('network failure')),
      );

      await expectLater(first, throwsStateError);
      await Future<void>.delayed(Duration.zero);
      expect(requests, isEmpty);

      final retry = coalesceInFlightOrderRead(
        requests: requests,
        key: 'order-1|customer-1|forceRefresh:true',
        load: () => Future<int>.value(3),
      );

      await expectLater(retry, completion(3));
    });
  });
}
