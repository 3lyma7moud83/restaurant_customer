import 'package:flutter_test/flutter_test.dart';
import 'package:restaurant_customer/pages/order_chat_page.dart';

void main() {
  test('chat pages merge by id and retain chronological order', () {
    final merged = mergeOrderChatMessages([
      {'id': '2', 'created_at': '2026-01-01T10:02:00Z', 'message': 'new'},
    ], [
      {'id': '1', 'created_at': '2026-01-01T10:01:00Z', 'message': 'old'},
      {'id': '2', 'created_at': '2026-01-01T10:02:00Z', 'message': 'new'},
    ]);

    expect(merged.map((message) => message['id']), ['1', '2']);
  });
}
