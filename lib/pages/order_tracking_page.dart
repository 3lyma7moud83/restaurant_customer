import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../cart/cart_provider.dart';
import '../core/orders/order_status_utils.dart';
import '../core/orders/order_ui.dart';
import '../core/realtime/realtime_channel_controller.dart';
import '../services/orders_service.dart';
import 'order_chat_page.dart';

class OrderTrackingPage extends StatefulWidget {
  const OrderTrackingPage({
    super.key,
    required this.orderId,
  });

  final String orderId;

  @override
  State<OrderTrackingPage> createState() => _OrderTrackingPageState();
}

class _OrderTrackingPageState extends State<OrderTrackingPage> {
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
      topicPrefix: 'tracking-order-${widget.orderId}',
      onSubscribed: (didReconnect) async {
        if (didReconnect) {
          await _loadData();
        }
      },
    );

    _itemsChannelController = RealtimeChannelController(
      client: _supabase,
      topicPrefix: 'tracking-items-${widget.orderId}',
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
        _errorMessage = 'تعذر تحميل بيانات التتبع.';
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
        title: const Text('تتبع الطلب'),
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
                ? _TrackingErrorState(
                    key: const ValueKey('error'),
                    message: _errorMessage ?? 'تعذر تحميل التتبع.',
                    onRetry: () => _loadData(showLoader: true),
                  )
                : RefreshIndicator(
                    key: const ValueKey('content'),
                    onRefresh: _loadData,
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                      children: [
                        _TrackingHeader(order: order),
                        const SizedBox(height: 16),
                        _TrackingProgressCard(order: order),
                        const SizedBox(height: 16),
                        _TrackingMapCard(order: order),
                        const SizedBox(height: 16),
                        _TrackingRestaurantCard(
                          order: order,
                          onCall: _callRestaurant,
                        ),
                        const SizedBox(height: 16),
                        _TrackingAddressCard(order: order),
                        const SizedBox(height: 16),
                        _TrackingItemsCard(
                          items: _items,
                          totalPrice: OrdersService.totalPriceOf(order),
                          deliveryCost: OrdersService.deliveryCostOf(order),
                        ),
                      ],
                    ),
                  ),
      ),
      floatingActionButton: order == null
          ? null
          : FloatingActionButton.extended(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => OrderChatPage(orderId: widget.orderId),
                  ),
                );
              },
              icon: const Icon(Icons.chat_bubble_outline),
              label: const Text('محادثة'),
            ),
    );
  }
}

class _TrackingHeader extends StatelessWidget {
  const _TrackingHeader({
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
          _TrackingMetaRow(
            icon: Icons.payments_outlined,
            label: 'الإجمالي',
            value: formatPrice(OrdersService.totalPriceOf(order)),
          ),
          const SizedBox(height: 10),
          _TrackingMetaRow(
            icon: Icons.calendar_today_outlined,
            label: 'تاريخ الطلب',
            value: formatOrderDate(OrdersService.createdAtOf(order)),
          ),
        ],
      ),
    );
  }
}

class _TrackingProgressCard extends StatelessWidget {
  const _TrackingProgressCard({
    required this.order,
  });

  final Map<String, dynamic> order;

  @override
  Widget build(BuildContext context) {
    final status = resolveOrderStatus(order['status']?.toString());

    final steps = [
      _ProgressStep(
        title: 'تم قبول الطلب',
        subtitle: 'المطعم أكد الطلب وبدأ تجهيزه.',
        active: status.trackingProgressIndex >= 1,
        color: orderStatusInfo(OrderStatusStage.accepted).color,
      ),
      _ProgressStep(
        title: 'الطلب في الطريق',
        subtitle: 'الطلب يتحرك الآن إلى عنوانك.',
        active: status.trackingProgressIndex >= 2,
        color: orderStatusInfo(OrderStatusStage.onTheWay).color,
      ),
      _ProgressStep(
        title: 'تم إغلاق الرحلة',
        subtitle: status.stage == OrderStatusStage.cancelled
            ? 'تم إلغاء الطلب.'
            : 'تم اكتمال الطلب بنجاح.',
        active: status.stage == OrderStatusStage.completed ||
            status.stage == OrderStatusStage.cancelled,
        color: status.stage == OrderStatusStage.cancelled
            ? orderStatusInfo(OrderStatusStage.cancelled).color
            : orderStatusInfo(OrderStatusStage.completed).color,
      ),
    ];

    return OrderSectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'حالة الطلب الحالية',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            status.text,
            style: TextStyle(
              color: status.color,
              fontWeight: FontWeight.w800,
              fontSize: 18,
            ),
          ),
          const SizedBox(height: 16),
          ...steps.map((step) => Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: step,
              )),
        ],
      ),
    );
  }
}

class _TrackingMapCard extends StatelessWidget {
  const _TrackingMapCard({
    required this.order,
  });

  final Map<String, dynamic> order;

  @override
  Widget build(BuildContext context) {
    final restaurantLat = OrdersService.restaurantLatOf(order);
    final restaurantLng = OrdersService.restaurantLngOf(order);
    final customerLat = OrdersService.customerLatOf(order);
    final customerLng = OrdersService.customerLngOf(order);
    final driverLat = OrdersService.driverLatOf(order);
    final driverLng = OrdersService.driverLngOf(order);

    final markers = <Marker>[];
    final points = <LatLng>[];

    if (restaurantLat != null && restaurantLng != null) {
      final point = LatLng(restaurantLat, restaurantLng);
      points.add(point);
      markers.add(
        Marker(
          point: point,
          width: 48,
          height: 48,
          child: _MapMarker(
            icon: Icons.storefront_rounded,
            color: const Color(0xFF1E88E5),
          ),
        ),
      );
    }

    if (customerLat != null && customerLng != null) {
      final point = LatLng(customerLat, customerLng);
      points.add(point);
      markers.add(
        Marker(
          point: point,
          width: 48,
          height: 48,
          child: _MapMarker(
            icon: Icons.location_on_rounded,
            color: const Color(0xFF2E7D32),
          ),
        ),
      );
    }

    if (driverLat != null && driverLng != null) {
      final point = LatLng(driverLat, driverLng);
      points.add(point);
      markers.add(
        Marker(
          point: point,
          width: 48,
          height: 48,
          child: _MapMarker(
            icon: Icons.delivery_dining_rounded,
            color: const Color(0xFFFB8C00),
          ),
        ),
      );
    }

    if (points.isEmpty) {
      return OrderSectionCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const [
            Text(
              'الخريطة',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            ),
            SizedBox(height: 14),
            Text(
              'بيانات المواقع غير متاحة لهذا الطلب حالياً.',
              style: TextStyle(color: Color(0xFF667085)),
            ),
          ],
        ),
      );
    }

    final center = _averagePoint(points);

    return OrderSectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'موقع المطعم والعميل',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: SizedBox(
              height: 260,
              child: FlutterMap(
                options: MapOptions(
                  initialCenter: center,
                  initialZoom: points.length > 1 ? 12.5 : 15,
                ),
                children: [
                  TileLayer(
                    urlTemplate:
                        'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: 'restaurant_customer',
                  ),
                  MarkerLayer(markers: markers),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: const [
              _LegendChip(
                icon: Icons.storefront_rounded,
                label: 'المطعم',
                color: Color(0xFF1E88E5),
              ),
              _LegendChip(
                icon: Icons.location_on_rounded,
                label: 'العميل',
                color: Color(0xFF2E7D32),
              ),
              _LegendChip(
                icon: Icons.delivery_dining_rounded,
                label: 'المندوب',
                color: Color(0xFFFB8C00),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static LatLng _averagePoint(List<LatLng> points) {
    var lat = 0.0;
    var lng = 0.0;
    for (final point in points) {
      lat += point.latitude;
      lng += point.longitude;
    }

    return LatLng(lat / points.length, lng / points.length);
  }
}

class _TrackingRestaurantCard extends StatelessWidget {
  const _TrackingRestaurantCard({
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
          _TrackingMetaRow(
            icon: Icons.storefront_outlined,
            label: 'الاسم',
            value: OrdersService.restaurantNameOf(order),
          ),
          const SizedBox(height: 10),
          _TrackingMetaRow(
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

class _TrackingAddressCard extends StatelessWidget {
  const _TrackingAddressCard({
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
            _TrackingMetaRow(
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

class _TrackingItemsCard extends StatelessWidget {
  const _TrackingItemsCard({
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

class _TrackingMetaRow extends StatelessWidget {
  const _TrackingMetaRow({
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

class _ProgressStep extends StatelessWidget {
  const _ProgressStep({
    required this.title,
    required this.subtitle,
    required this.active,
    required this.color,
  });

  final String title;
  final String subtitle;
  final bool active;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final effectiveColor = active ? color : const Color(0xFFD0D5DD);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: effectiveColor,
            shape: BoxShape.circle,
          ),
          child: active
              ? const Icon(Icons.check, size: 16, color: Colors.white)
              : null,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: active ? color : const Color(0xFF667085),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: const TextStyle(
                  color: Color(0xFF667085),
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _LegendChip extends StatelessWidget {
  const _LegendChip({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _MapMarker extends StatelessWidget {
  const _MapMarker({
    required this.icon,
    required this.color,
  });

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: const [
          BoxShadow(
            color: Color(0x22000000),
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      padding: const EdgeInsets.all(10),
      child: Icon(icon, color: color, size: 22),
    );
  }
}

class _TrackingErrorState extends StatelessWidget {
  const _TrackingErrorState({
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
              Icons.route_outlined,
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
