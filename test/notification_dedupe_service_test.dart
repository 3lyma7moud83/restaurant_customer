import 'package:flutter_test/flutter_test.dart';
import 'package:restaurant_customer/core/stability/notification_dedupe_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('deduplicates one notification identity across lifecycle sources',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final service = NotificationDedupeService.instance;

    expect(
      await service.shouldProcess(
        fingerprint: 'notification:audit-test-id',
        source: 'foreground_push',
        dedupeWindow: const Duration(hours: 6),
      ),
      isTrue,
    );
    expect(
      await service.shouldProcess(
        fingerprint: 'notification:audit-test-id',
        source: 'background_push',
        dedupeWindow: const Duration(hours: 6),
      ),
      isFalse,
    );
  });
}
