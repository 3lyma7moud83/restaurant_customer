import 'package:flutter_test/flutter_test.dart';
import 'package:restaurant_customer/core/errors/app_error.dart';
import 'package:restaurant_customer/core/errors/error_reporter.dart';
import 'package:restaurant_customer/core/errors/error_type.dart';

AppError _error({
  required ErrorSeverity severity,
  int occurrences = 1,
  String message = 'first',
}) {
  return AppError(
    code: 'network_error',
    type: ErrorType.network,
    severity: severity,
    message: message,
    userMessage: 'تعذر الاتصال',
    rawError: message,
    stackTrace: StackTrace.empty,
    screen: 'orders',
    action: 'load',
    module: 'orders_service',
    appName: 'customer',
    userId: 'user',
    restaurantId: null,
    driverId: null,
    deviceInfo: 'test',
    osInfo: 'test',
    appVersion: 'test',
    internetStatus: 'wifi',
    createdAt: DateTime.utc(2026, 1, 1),
    fingerprint: 'same-error',
    occurrences: occurrences,
  );
}

void main() {
  test('only low and medium severity errors are batched', () {
    expect(shouldBatchRepeatedError(ErrorSeverity.low), isTrue);
    expect(shouldBatchRepeatedError(ErrorSeverity.medium), isTrue);
    expect(shouldBatchRepeatedError(ErrorSeverity.high), isFalse);
    expect(shouldBatchRepeatedError(ErrorSeverity.critical), isFalse);
  });

  test('repeated errors retain the latest diagnostics and total occurrences',
      () {
    final merged = mergeRepeatedErrors(
      _error(severity: ErrorSeverity.medium, occurrences: 2),
      _error(
        severity: ErrorSeverity.medium,
        occurrences: 3,
        message: 'latest',
      ),
    );

    expect(merged.occurrences, 5);
    expect(merged.message, 'latest');
  });
}
