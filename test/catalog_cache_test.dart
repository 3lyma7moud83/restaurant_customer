import 'package:flutter_test/flutter_test.dart';
import 'package:restaurant_customer/services/categories_service.dart';
import 'package:restaurant_customer/services/items_service.dart';

void main() {
  final cachedAt = DateTime(2026, 10, 11, 12);

  group('catalog cache freshness', () {
    test('uses valid category and item cache entries', () {
      final now = cachedAt.add(const Duration(minutes: 4, seconds: 59));

      expect(
        CategoriesService.isCacheFresh(cachedAt: cachedAt, now: now),
        isTrue,
      );
      expect(
        ItemsService.isCacheFresh(cachedAt: cachedAt, now: now),
        isTrue,
      );
    });

    test('refreshes category and item cache entries after five minutes', () {
      final now = cachedAt.add(const Duration(minutes: 5, microseconds: 1));

      expect(
        CategoriesService.isCacheFresh(cachedAt: cachedAt, now: now),
        isFalse,
      );
      expect(
        ItemsService.isCacheFresh(cachedAt: cachedAt, now: now),
        isFalse,
      );
    });
  });
}
