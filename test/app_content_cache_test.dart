import 'package:flutter_test/flutter_test.dart';
import 'package:restaurant_customer/services/app_content_service.dart';

void main() {
  test('content cache remains valid through its configured TTL', () {
    final cachedAt = DateTime.utc(2026, 1, 1, 12);

    expect(
      isAppContentCacheFresh(
        cachedAt: cachedAt,
        now: cachedAt.add(const Duration(minutes: 10)),
      ),
      isTrue,
    );
    expect(
      isAppContentCacheFresh(
        cachedAt: cachedAt,
        now: cachedAt.add(const Duration(minutes: 10, seconds: 1)),
      ),
      isFalse,
    );
  });

  test('English fallback is fetched only when the active language is absent',
      () {
    expect(
      shouldFetchEnglishContentFallback(
        language: 'ar',
        hasCurrentLanguageEntry: true,
      ),
      isFalse,
    );
    expect(
      shouldFetchEnglishContentFallback(
        language: 'ar',
        hasCurrentLanguageEntry: false,
      ),
      isTrue,
    );
  });
}
