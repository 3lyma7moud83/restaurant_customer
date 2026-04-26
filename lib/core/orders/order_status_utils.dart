import 'package:flutter/material.dart';

enum OrderStatusStage {
  pending,
  accepted,
  onTheWay,
  completed,
  cancelled,
  unknown,
}

class OrderStatusInfo {
  const OrderStatusInfo({
    required this.stage,
    required this.text,
    required this.color,
    required this.icon,
    required this.rawValue,
  });

  final OrderStatusStage stage;
  final String text;
  final Color color;
  final IconData icon;
  final String rawValue;

  bool get canTrack {
    return stage == OrderStatusStage.accepted ||
        stage == OrderStatusStage.onTheWay;
  }

  bool get shouldTrackDriver => stage == OrderStatusStage.onTheWay;

  bool get isActive {
    return stage == OrderStatusStage.pending ||
        stage == OrderStatusStage.accepted ||
        stage == OrderStatusStage.onTheWay;
  }

  bool get isTerminal {
    return stage == OrderStatusStage.completed ||
        stage == OrderStatusStage.cancelled;
  }

  int get trackingProgressIndex {
    switch (stage) {
      case OrderStatusStage.pending:
        return 0;
      case OrderStatusStage.accepted:
        return 1;
      case OrderStatusStage.onTheWay:
        return 2;
      case OrderStatusStage.completed:
        return 3;
      case OrderStatusStage.cancelled:
      case OrderStatusStage.unknown:
        return 0;
    }
  }
}

OrderStatusInfo resolveOrderStatus(String? rawStatus) {
  final normalized = normalizeOrderStatus(rawStatus);

  switch (normalized) {
    case 'pending':
    case 'pending_cashier':
      return const OrderStatusInfo(
        stage: OrderStatusStage.pending,
        text: 'قيد الانتظار',
        color: Color(0xFFF4B400),
        icon: Icons.hourglass_top_rounded,
        rawValue: 'pending',
      );
    case 'accepted':
    case 'confirmed':
      return const OrderStatusInfo(
        stage: OrderStatusStage.accepted,
        text: 'قيد التحضير',
        color: Color(0xFF1E88E5),
        icon: Icons.restaurant_rounded,
        rawValue: 'accepted',
      );
    case 'on_the_way':
    case 'on_theway':
    case 'onway':
    case 'on_way':
    case 'arrived':
    case 'delivered':
      return const OrderStatusInfo(
        stage: OrderStatusStage.onTheWay,
        text: 'في الطريق',
        color: Color(0xFFFB8C00),
        icon: Icons.delivery_dining_rounded,
        rawValue: 'on_the_way',
      );
    case 'completed':
    case 'done':
    case 'delivered_final':
    case 'delivered_confirmed':
    case 'delivery_confirmed':
    case 'received':
      return const OrderStatusInfo(
        stage: OrderStatusStage.completed,
        text: 'تم التسليم',
        color: Color(0xFF2E7D32),
        icon: Icons.task_alt_rounded,
        rawValue: 'completed',
      );
    case 'cancelled':
    case 'canceled':
    case 'rejected':
      return const OrderStatusInfo(
        stage: OrderStatusStage.cancelled,
        text: 'ملغي',
        color: Color(0xFFC62828),
        icon: Icons.cancel_rounded,
        rawValue: 'cancelled',
      );
    default:
      return const OrderStatusInfo(
        stage: OrderStatusStage.unknown,
        text: 'قيد التحديث',
        color: Colors.grey,
        icon: Icons.sync_problem_rounded,
        rawValue: 'unknown',
      );
  }
}

OrderStatusInfo orderStatusInfo(OrderStatusStage stage) {
  return switch (stage) {
    OrderStatusStage.pending => resolveOrderStatus('pending'),
    OrderStatusStage.accepted => resolveOrderStatus('accepted'),
    OrderStatusStage.onTheWay => resolveOrderStatus('on_the_way'),
    OrderStatusStage.completed => resolveOrderStatus('completed'),
    OrderStatusStage.cancelled => resolveOrderStatus('cancelled'),
    OrderStatusStage.unknown => resolveOrderStatus(null),
  };
}

OrderStatusStage parseOrderStatus(String? rawStatus) {
  return resolveOrderStatus(rawStatus).stage;
}

String normalizeOrderStatus(String? rawStatus) {
  return rawStatus
          ?.trim()
          .toLowerCase()
          .replaceAll('-', '_')
          .replaceAll(' ', '_') ??
      '';
}
