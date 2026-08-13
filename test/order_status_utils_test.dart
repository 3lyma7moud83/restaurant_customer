import 'package:flutter_test/flutter_test.dart';
import 'package:restaurant_customer/core/orders/order_status_utils.dart';

void main() {
  group('resolveOrderStatus', () {
    test('maps server status aliases to the expected stage', () {
      expect(parseOrderStatus('accepted'), OrderStatusStage.accepted);
      expect(parseOrderStatus('prepared'), OrderStatusStage.accepted);
      expect(parseOrderStatus('ready'), OrderStatusStage.accepted);
      expect(parseOrderStatus('assigned'), OrderStatusStage.accepted);
      expect(parseOrderStatus('ready_for_delivery'), OrderStatusStage.accepted);
      expect(parseOrderStatus('on_the_way'), OrderStatusStage.onTheWay);
      expect(parseOrderStatus('on-way'), OrderStatusStage.onTheWay);
      expect(parseOrderStatus('delivered'), OrderStatusStage.onTheWay);
      expect(
        parseOrderStatus('awaiting_customer_confirmation'),
        OrderStatusStage.awaitingCustomerConfirmation,
      );
      expect(parseOrderStatus('completed'), OrderStatusStage.completed);
      expect(parseOrderStatus('cancelled'), OrderStatusStage.cancelled);
    });

    test('exposes tracking flags consistently', () {
      expect(orderStatusInfo(OrderStatusStage.accepted).canTrack, isTrue);
      expect(
          orderStatusInfo(OrderStatusStage.onTheWay).shouldTrackDriver, isTrue);
      expect(
          orderStatusInfo(OrderStatusStage.completed).trackingProgressIndex, 3);
      expect(
        orderStatusInfo(OrderStatusStage.awaitingCustomerConfirmation)
            .trackingProgressIndex,
        3,
      );
      expect(
        orderStatusInfo(OrderStatusStage.awaitingCustomerConfirmation).isActive,
        isTrue,
      );
      expect(
        orderStatusInfo(OrderStatusStage.awaitingCustomerConfirmation)
            .isTerminal,
        isFalse,
      );
      expect(orderStatusInfo(OrderStatusStage.cancelled).canTrack, isFalse);
    });

    test('exposes customer-facing labels and active-order helpers', () {
      expect(resolveOrderStatus('accepted').text, 'قيد التحضير');
      expect(resolveOrderStatus('delivered').text, 'الطيار استلم الطلب');
      expect(
        resolveOrderStatus('awaiting_customer_confirmation').text,
        'تم التسليم - بانتظار تأكيد الاستلام',
      );
      expect(resolveOrderStatus('completed').text, 'اكتمل الطلب');
      expect(resolveOrderStatus('rejected').text, 'تم إلغاء الطلب');
      expect(isBlockingActiveOrderStatus('pending_cashier'), isTrue);
      expect(isBlockingActiveOrderStatus('ready_for_delivery'), isTrue);
      expect(isBlockingActiveOrderStatus('completed'), isFalse);
      expect(
        shouldOpenTrackingPageForOrderStatus('awaiting_customer_confirmation'),
        isTrue,
      );
      expect(shouldOpenTrackingPageForOrderStatus('rejected'), isFalse);
    });
  });
}
