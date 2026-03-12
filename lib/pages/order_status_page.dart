import 'package:flutter/material.dart';

import 'order_details_page.dart';

class OrderStatusPage extends StatelessWidget {
  const OrderStatusPage({
    super.key,
    required this.orderId,
  });

  final String orderId;

  @override
  Widget build(BuildContext context) {
    return OrderDetailsPage(orderId: orderId);
  }
}
