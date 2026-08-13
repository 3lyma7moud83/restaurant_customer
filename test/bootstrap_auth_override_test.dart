import 'package:flutter_test/flutter_test.dart';
import 'package:restaurant_customer/core/config/bootstrap_auth_override.dart';

void main() {
  group('BootstrapAuthOverride', () {
    test('returns null when credentials are absent', () {
      expect(
        BootstrapAuthOverride.fromEnvironment(
          email: '',
          password: '',
        ),
        isNull,
      );
    });

    test('returns an override when both credentials are present', () {
      final override = BootstrapAuthOverride.fromEnvironment(
        email: 'test@example.com',
        password: 'secret123',
      );

      expect(override, isNotNull);
      expect(override!.email, 'test@example.com');
      expect(override.password, 'secret123');
    });
  });
}
