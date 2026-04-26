import 'package:flutter_test/flutter_test.dart';
import 'package:restaurant_customer/core/orders/order_status_utils.dart';

void main() {
  group('resolveOrderStatus', () {
    test('maps server status aliases to the expected stage', () {
      expect(parseOrderStatus('accepted'), OrderStatusStage.accepted);
      expect(parseOrderStatus('on_the_way'), OrderStatusStage.onTheWay);
      expect(parseOrderStatus('on-way'), OrderStatusStage.onTheWay);
      expect(parseOrderStatus('delivered'), OrderStatusStage.onTheWay);
      expect(parseOrderStatus('completed'), OrderStatusStage.completed);
      expect(parseOrderStatus('cancelled'), OrderStatusStage.cancelled);
    });

    test('exposes tracking flags consistently', () {
      expect(orderStatusInfo(OrderStatusStage.accepted).canTrack, isTrue);
      expect(
          orderStatusInfo(OrderStatusStage.onTheWay).shouldTrackDriver, isTrue);
      expect(
          orderStatusInfo(OrderStatusStage.completed).trackingProgressIndex, 3);
      expect(orderStatusInfo(OrderStatusStage.cancelled).canTrack, isFalse);
    });
  });
}
