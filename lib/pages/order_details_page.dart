import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../cart/cart_provider.dart';
import '../core/orders/order_status_utils.dart';
import '../core/orders/order_ui.dart';
import '../core/realtime/realtime_channel_controller.dart';
import '../services/orders_service.dart';
import 'order_tracking_page.dart';

class OrderDetailsPage extends StatefulWidget {
  const OrderDetailsPage({
    super.key,
    required this.orderId,
  });

  final String orderId;

  @override
  State<OrderDetailsPage> createState() => _OrderDetailsPageState();
}

class _OrderDetailsPageState extends State<OrderDetailsPage> {
  final _supabase = Supabase.instance.client;

  late final RealtimeChannelController _orderChannelController;
  late final RealtimeChannelController _itemsChannelController;

  bool _loading = true;
  String? _errorMessage;
  Map<String, dynamic>? _order;
  List<Map<String, dynamic>> _items = const [];

  @override
  void initState() {
    super.initState();

    _orderChannelController = RealtimeChannelController(
      client: _supabase,
      topicPrefix: 'order-details-${widget.orderId}',
      onSubscribed: (didReconnect) async {
        if (didReconnect) {
          await _loadData();
        }
      },
    );

    _itemsChannelController = RealtimeChannelController(
      client: _supabase,
      topicPrefix: 'order-details-items-${widget.orderId}',
      onSubscribed: (didReconnect) async {
        if (didReconnect) {
          await _loadItems();
        }
      },
    );

    _listenToRealtime();
    unawaited(_loadData(showLoader: true));
  }

  @override
  void dispose() {
    unawaited(_orderChannelController.dispose());
    unawaited(_itemsChannelController.dispose());
    super.dispose();
  }

  void _listenToRealtime() {
    _orderChannelController.subscribe((client, channelName) {
      return client.channel(channelName).onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'orders',
            filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'id',
              value: widget.orderId,
            ),
            callback: _handleOrderChange,
          );
    });

    _itemsChannelController.subscribe((client, channelName) {
      return client.channel(channelName).onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'order_items',
            filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'order_id',
              value: widget.orderId,
            ),
            callback: _handleItemsChange,
          );
    });
  }

  Future<void> _loadData({bool showLoader = false}) async {
    if (showLoader && mounted) {
      setState(() {
        _loading = true;
        _errorMessage = null;
      });
    }

    try {
      final results = await Future.wait([
        OrdersService.getOrderById(widget.orderId),
        OrdersService.getOrderItems(widget.orderId),
      ]);

      final order = results[0] as Map<String, dynamic>?;
      final items = results[1] as List<Map<String, dynamic>>;

      if (!mounted) {
        return;
      }

      if (order == null) {
        setState(() {
          _order = null;
          _items = const [];
          _loading = false;
          _errorMessage = 'تعذر العثور على الطلب.';
        });
        return;
      }

      CartProvider.maybeOf(context)?.syncOrderStatusFromRow(order);

      setState(() {
        _order = order;
        _items = _sortedItems(items);
        _loading = false;
        _errorMessage = null;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }

      setState(() {
        _loading = false;
        _errorMessage = 'تعذر تحميل تفاصيل الطلب.';
      });
    }
  }

  Future<void> _loadItems() async {
    try {
      final items = await OrdersService.getOrderItems(widget.orderId);
      if (!mounted) {
        return;
      }
      setState(() => _items = _sortedItems(items));
    } catch (_) {}
  }

  Future<void> _loadOrderOnly() async {
    try {
      final order = await OrdersService.getOrderById(widget.orderId);
      if (!mounted || order == null) {
        return;
      }
      CartProvider.maybeOf(context)?.syncOrderStatusFromRow(order);
      setState(() => _order = order);
    } catch (_) {}
  }

  List<Map<String, dynamic>> _sortedItems(List<Map<String, dynamic>> items) {
    final nextItems = List<Map<String, dynamic>>.from(items);
    nextItems.sort(
      (a, b) => OrdersService.createdAtOf(a).compareTo(
        OrdersService.createdAtOf(b),
      ),
    );
    return nextItems;
  }

  void _handleOrderChange(PostgresChangePayload payload) {
    if (payload.eventType == PostgresChangeEvent.delete) {
      if (!mounted) {
        return;
      }
      setState(() {
        _order = {
          ...?_order,
          'status': 'cancelled',
        };
      });
      return;
    }

    unawaited(_loadOrderOnly());
  }

  void _handleItemsChange(PostgresChangePayload payload) {
    switch (payload.eventType) {
      case PostgresChangeEvent.delete:
      case PostgresChangeEvent.insert:
      case PostgresChangeEvent.update:
        unawaited(_loadItems());
        break;
      case PostgresChangeEvent.all:
        break;
    }
  }

  Future<void> _callRestaurant(String phone) async {
    final uri = Uri.parse('tel:$phone');
    if (!await canLaunchUrl(uri)) {
      return;
    }
    await launchUrl(uri);
  }

  @override
  Widget build(BuildContext context) {
    final order = _order;

    return Scaffold(
      backgroundColor: const Color(0xFFF6F7FB),
      appBar: AppBar(
        title: const Text('تفاصيل الطلب'),
        centerTitle: true,
      ),
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        child: _loading
            ? const Center(
                key: ValueKey('loading'),
                child: CircularProgressIndicator(),
              )
            : order == null
                ? _OrderDetailsErrorState(
                    key: const ValueKey('error'),
                    message: _errorMessage ?? 'تعذر تحميل الطلب.',
                    onRetry: () => _loadData(showLoader: true),
                  )
                : RefreshIndicator(
                    key: const ValueKey('content'),
                    onRefresh: _loadData,
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                      children: [
                        _HeaderCard(order: order),
                        const SizedBox(height: 16),
                        _RestaurantCard(
                          order: order,
                          onCall: _callRestaurant,
                        ),
                        const SizedBox(height: 16),
                        _AddressCard(order: order),
                        const SizedBox(height: 16),
                        _ItemsCard(
                          items: _items,
                          totalPrice: OrdersService.totalPriceOf(order),
                          deliveryCost: OrdersService.deliveryCostOf(order),
                        ),
                        if (resolveOrderStatus(order['status']?.toString())
                            .canTrack) ...[
                          const SizedBox(height: 16),
                          ElevatedButton.icon(
                            onPressed: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => OrderTrackingPage(
                                    orderId: widget.orderId,
                                  ),
                                ),
                              );
                            },
                            icon: const Icon(Icons.map_outlined),
                            label: const Text('فتح التتبع'),
                          ),
                        ],
                      ],
                    ),
                  ),
      ),
    );
  }
}

class _HeaderCard extends StatelessWidget {
  const _HeaderCard({
    required this.order,
  });

  final Map<String, dynamic> order;

  @override
  Widget build(BuildContext context) {
    final statusInfo = resolveOrderStatus(order['status']?.toString());

    return OrderSectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  'ريسيت #${OrdersService.receiptNumberOf(order)}',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              OrderStatusBadge(info: statusInfo),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            OrdersService.restaurantNameOf(order),
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 14),
          _MetaRow(
            icon: Icons.payments_outlined,
            label: 'الإجمالي',
            value: formatPrice(OrdersService.totalPriceOf(order)),
          ),
          const SizedBox(height: 10),
          _MetaRow(
            icon: Icons.calendar_today_outlined,
            label: 'تاريخ الطلب',
            value: formatOrderDate(OrdersService.createdAtOf(order)),
          ),
        ],
      ),
    );
  }
}

class _RestaurantCard extends StatelessWidget {
  const _RestaurantCard({
    required this.order,
    required this.onCall,
  });

  final Map<String, dynamic> order;
  final Future<void> Function(String phone) onCall;

  @override
  Widget build(BuildContext context) {
    final phone = OrdersService.restaurantPhoneOf(order);

    return OrderSectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'بيانات المطعم',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 14),
          _MetaRow(
            icon: Icons.storefront_outlined,
            label: 'الاسم',
            value: OrdersService.restaurantNameOf(order),
          ),
          const SizedBox(height: 10),
          _MetaRow(
            icon: Icons.person_outline,
            label: 'اسم العميل',
            value: OrdersService.customerNameOf(order),
          ),
          if (phone != null && phone.isNotEmpty) ...[
            const SizedBox(height: 14),
            OutlinedButton.icon(
              onPressed: () => onCall(phone),
              icon: const Icon(Icons.phone_outlined),
              label: Text(phone),
            ),
          ],
        ],
      ),
    );
  }
}

class _AddressCard extends StatelessWidget {
  const _AddressCard({
    required this.order,
  });

  final Map<String, dynamic> order;

  @override
  Widget build(BuildContext context) {
    final phone = OrdersService.customerPhoneOf(order);

    return OrderSectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'عنوان التوصيل',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.location_on_outlined, color: Color(0xFF667085)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  OrdersService.addressOf(order),
                  style: const TextStyle(
                    height: 1.5,
                    color: Color(0xFF344054),
                  ),
                ),
              ),
            ],
          ),
          if (phone != null && phone.isNotEmpty) ...[
            const SizedBox(height: 12),
            _MetaRow(
              icon: Icons.phone_android_outlined,
              label: 'رقم العميل',
              value: phone,
            ),
          ],
        ],
      ),
    );
  }
}

class _ItemsCard extends StatelessWidget {
  const _ItemsCard({
    required this.items,
    required this.totalPrice,
    required this.deliveryCost,
  });

  final List<Map<String, dynamic>> items;
  final double totalPrice;
  final double deliveryCost;

  @override
  Widget build(BuildContext context) {
    final subtotal =
        totalPrice - deliveryCost > 0 ? totalPrice - deliveryCost : totalPrice;

    return OrderSectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'الأصناف',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 14),
          if (items.isEmpty)
            const Text(
              'لا توجد عناصر مرتبطة بهذا الطلب.',
              style: TextStyle(color: Color(0xFF667085)),
            )
          else
            ...items.map((item) {
              final qty = OrdersService.quantityOfItem(item);
              final price = OrdersService.itemPriceOf(item);
              final lineTotal = price * qty;

              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '$qty x ${OrdersService.itemNameOf(item)}',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    Text(
                      formatPrice(lineTotal),
                      style: const TextStyle(color: Color(0xFF475467)),
                    ),
                  ],
                ),
              );
            }),
          const Divider(height: 28),
          Row(
            children: [
              Text(
                formatPrice(subtotal),
                style: const TextStyle(
                  color: Color(0xFF475467),
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              const Text(
                'سعر الطلب',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Text(
                formatPrice(deliveryCost),
                style: const TextStyle(
                  color: Color(0xFF475467),
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              const Text(
                'التوصيل',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const Divider(height: 28),
          Row(
            children: [
              const Text(
                'الإجمالي النهائي',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
              const Spacer(),
              Text(
                formatPrice(totalPrice),
                style: const TextStyle(
                  color: Color(0xFF2E7D32),
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MetaRow extends StatelessWidget {
  const _MetaRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: const Color(0xFF667085)),
        const SizedBox(width: 8),
        Text(
          '$label: ',
          style: const TextStyle(
            color: Color(0xFF667085),
            fontWeight: FontWeight.w700,
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(
              color: Color(0xFF101828),
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

class _OrderDetailsErrorState extends StatelessWidget {
  const _OrderDetailsErrorState({
    super.key,
    required this.message,
    required this.onRetry,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.error_outline_rounded,
              size: 46,
              color: Color(0xFF98A2B3),
            ),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 14),
            OutlinedButton(
              onPressed: onRetry,
              child: const Text('إعادة المحاولة'),
            ),
          ],
        ),
      ),
    );
  }
}
