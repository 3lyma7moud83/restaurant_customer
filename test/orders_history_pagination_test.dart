import 'package:flutter_test/flutter_test.dart';
import 'package:restaurant_customer/services/orders_service.dart';

void main() {
  test('order history page range is contiguous and bounded', () {
    expect(
      orderHistoryPageRange(page: 0, pageSize: 25),
      (from: 0, to: 24),
    );
    expect(
      orderHistoryPageRange(page: 2, pageSize: 25),
      (from: 50, to: 74),
    );
  });
}
