import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../cart/cart_provider.dart';
import '../core/orders/order_status_utils.dart';
import '../core/orders/order_ui.dart';
import '../core/realtime/realtime_channel_controller.dart';
import '../core/theme/app_theme.dart';
import '../services/orders_service.dart';
import '../services/session_manager.dart';
import 'order_details_page.dart';
import 'order_tracking_page.dart';

class OrdersPage extends StatefulWidget {
  const OrdersPage({super.key});

  @override
  State<OrdersPage> createState() => _OrdersPageState();
}

class _OrdersPageState extends State<OrdersPage> {
  final _supabase = Supabase.instance.client;

  late final RealtimeChannelController _ordersChannelController;
  Timer? _ordersRealtimeDebounce;
  final Set<String> _pendingRealtimeOrderIds = <String>{};
  bool _needsRealtimeFullRefresh = false;

  bool _loading = true;
  String? _userId;
  String? _errorMessage;
  List<Map<String, dynamic>> _orders = const [];

  @override
  void initState() {
    super.initState();

    _ordersChannelController = RealtimeChannelController(
      client: _supabase,
      topicPrefix: 'customer-orders-page-${identityHashCode(this)}',
      onSubscribed: (didReconnect) async {
        if (didReconnect) {
          await _loadOrders(forceRefresh: true);
        }
      },
    );

    unawaited(_initialize());
  }

  @override
  void dispose() {
    _ordersRealtimeDebounce?.cancel();
    unawaited(_ordersChannelController.dispose());
    super.dispose();
  }

  Future<void> _initialize() async {
    final session = await SessionManager.instance.ensureValidSession(
      requireSession: true,
    );
    _userId = session?.user.id;

    await _loadOrders(showLoader: true);
    if (!mounted || _userId == null) {
      return;
    }

    _listenToOrders();
  }

  Future<void> _loadOrders({
    bool showLoader = false,
    bool forceRefresh = false,
  }) async {
    final userId = _userId;
    if (showLoader && mounted) {
      setState(() {
        _loading = true;
        _errorMessage = null;
      });
    }

    if (userId == null) {
      if (!mounted) {
        return;
      }
      setState(() {
        _orders = const [];
        _loading = false;
      });
      return;
    }

    try {
      final result = await OrdersService.getCustomerOrders(
        userId,
        forceRefresh: forceRefresh,
      );
      if (!mounted) {
        return;
      }

      final cart = CartProvider.maybeOf(context);
      final activeOrderId = cart?.activeOrderId;
      if (cart != null && activeOrderId != null) {
        for (final order in result) {
          if (OrdersService.idOf(order) == activeOrderId) {
            cart.syncOrderStatusFromRow(order);
            break;
          }
        }
      }

      _applyOrdersSnapshot(result, isLoading: false, errorMessage: null);
    } catch (_) {
      if (!mounted) {
        return;
      }

      _applyOrdersSnapshot(
        const [],
        isLoading: false,
        errorMessage: 'تعذر تحميل الطلبات حالياً.',
      );
    }
  }

  void _listenToOrders() {
    final userId = _userId;
    if (userId == null) {
      return;
    }

    _ordersChannelController.subscribe((client, channelName) {
      return client.channel(channelName).onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'orders',
            filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'customer_id',
              value: userId,
            ),
            callback: _handleOrdersChange,
          );
    });
  }

  void _handleOrdersChange(PostgresChangePayload payload) {
    switch (payload.eventType) {
      case PostgresChangeEvent.delete:
        final orderId = payload.oldRecord['id']?.toString();
        if (orderId == null || orderId.isEmpty) {
          return;
        }
        _pendingRealtimeOrderIds.add(orderId);
        _needsRealtimeFullRefresh = true;
        break;
      case PostgresChangeEvent.insert:
        _needsRealtimeFullRefresh = true;
        final orderId = payload.newRecord['id']?.toString();
        if (orderId == null || orderId.isEmpty) {
          return;
        }
        _pendingRealtimeOrderIds.add(orderId);
        break;
      case PostgresChangeEvent.update:
        final orderId = payload.newRecord['id']?.toString();
        if (orderId == null || orderId.isEmpty) {
          return;
        }
        _pendingRealtimeOrderIds.add(orderId);
        break;
      case PostgresChangeEvent.all:
        break;
    }

    _scheduleRealtimeRefresh();
  }

  void _scheduleRealtimeRefresh() {
    _ordersRealtimeDebounce?.cancel();
    _ordersRealtimeDebounce = Timer(
      const Duration(milliseconds: 250),
      () {
        if (!mounted) {
          return;
        }

        final pendingIds = Set<String>.from(_pendingRealtimeOrderIds);
        final needsFullRefresh =
            _needsRealtimeFullRefresh || pendingIds.length != 1;

        _pendingRealtimeOrderIds.clear();
        _needsRealtimeFullRefresh = false;

        if (needsFullRefresh || pendingIds.isEmpty) {
          unawaited(_loadOrders(forceRefresh: true));
          return;
        }

        final orderId = pendingIds.first;
        final existsInList = _orders.any(
          (order) => OrdersService.idOf(order) == orderId,
        );
        if (!existsInList) {
          unawaited(_loadOrders(forceRefresh: true));
          return;
        }

        unawaited(_refreshOrder(orderId));
      },
    );
  }

  Future<void> _refreshOrder(String orderId) async {
    final row = await OrdersService.getOrderById(
      orderId,
      userId: _userId,
      forceRefresh: true,
    );
    if (!mounted) {
      return;
    }

    if (row == null) {
      _removeOrder(orderId);
      return;
    }

    CartProvider.maybeOf(context)?.syncOrderStatusFromRow(row);
    _upsertOrder(row);
  }

  void _upsertOrder(Map<String, dynamic> order) {
    final orderId = OrdersService.idOf(order);
    if (orderId.isEmpty) {
      return;
    }

    final nextOrders = List<Map<String, dynamic>>.from(_orders);
    final index =
        nextOrders.indexWhere((item) => OrdersService.idOf(item) == orderId);

    if (index != -1 && mapEquals(nextOrders[index], order)) {
      return;
    }

    if (index == -1) {
      nextOrders.insert(0, order);
    } else {
      nextOrders[index] = order;
    }

    _applyOrdersSnapshot(nextOrders, isLoading: false, errorMessage: null);
  }

  void _removeOrder(String orderId) {
    final nextOrders = _orders
        .where((item) => OrdersService.idOf(item) != orderId)
        .toList(growable: false);

    if (nextOrders.length == _orders.length) {
      return;
    }

    _applyOrdersSnapshot(nextOrders, isLoading: false, errorMessage: null);
  }

  void _applyOrdersSnapshot(
    List<Map<String, dynamic>> nextOrders, {
    required bool isLoading,
    required String? errorMessage,
  }) {
    final merged = _reuseOrderMaps(nextOrders);
    final listChanged = !_sameIdentityList(_orders, merged);

    if (!listChanged &&
        _loading == isLoading &&
        _errorMessage == errorMessage) {
      return;
    }

    setState(() {
      _orders = merged;
      _loading = isLoading;
      _errorMessage = errorMessage;
    });
  }

  List<Map<String, dynamic>> _reuseOrderMaps(
    List<Map<String, dynamic>> nextOrders,
  ) {
    final currentById = {
      for (final order in _orders) OrdersService.idOf(order): order,
    };

    final merged = nextOrders.map((order) {
      final current = currentById[OrdersService.idOf(order)];
      if (current != null && mapEquals(current, order)) {
        return current;
      }
      return order;
    }).toList(growable: false);

    merged.sort(
      (a, b) => OrdersService.createdAtOf(b).compareTo(
        OrdersService.createdAtOf(a),
      ),
    );

    return merged;
  }

  bool _sameIdentityList(
    List<Map<String, dynamic>> current,
    List<Map<String, dynamic>> next,
  ) {
    if (current.length != next.length) {
      return false;
    }

    for (var i = 0; i < current.length; i++) {
      if (!identical(current[i], next[i])) {
        return false;
      }
    }

    return true;
  }

  void _openOrder(Map<String, dynamic> order) {
    final orderId = OrdersService.idOf(order);
    if (orderId.isEmpty) {
      _showSnack('تعذر فتح الطلب حالياً.');
      return;
    }

    final status = OrdersService.statusStageOf(order);
    final route = AppTheme.platformPageRoute<void>(
      builder: (_) => status == OrderStatusStage.accepted ||
              status == OrderStatusStage.onTheWay
          ? OrderTrackingPage(orderId: orderId)
          : OrderDetailsPage(orderId: orderId),
    );

    Navigator.push(context, route);
  }

  void _showSnack(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6F7FB),
      appBar: AppBar(
        title: const Text('طلباتي'),
        centerTitle: true,
      ),
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        child: _loading
            ? const Center(
                key: ValueKey('loading'),
                child: CircularProgressIndicator(),
              )
            : _orders.isEmpty
                ? _errorMessage != null
                    ? _OrdersErrorState(
                        key: const ValueKey('error'),
                        message: _errorMessage!,
                        onRetry: () =>
                            _loadOrders(showLoader: true, forceRefresh: true),
                      )
                    : _OrdersEmptyState(
                        key: const ValueKey('empty'),
                        onOrderNow: () => Navigator.maybePop(context),
                      )
                : RefreshIndicator(
                    key: const ValueKey('list'),
                    onRefresh: () => _loadOrders(forceRefresh: true),
                    child: ListView.builder(
                      physics: AppTheme.bouncingScrollPhysics,
                      cacheExtent: 640,
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                      itemCount: _orders.length,
                      itemBuilder: (context, index) {
                        final order = _orders[index];
                        final duration = Duration(
                          milliseconds: 240 + math.min(index * 70, 320),
                        );

                        return TweenAnimationBuilder<double>(
                          key: ValueKey(
                            'order-${OrdersService.idOf(order)}-${OrdersService.normalizedStatusOf(order)}',
                          ),
                          tween: Tween(begin: 0, end: 1),
                          duration: duration,
                          curve: Curves.easeOutCubic,
                          builder: (context, value, child) {
                            return Opacity(
                              opacity: value,
                              child: Transform.translate(
                                offset: Offset(0, (1 - value) * 22),
                                child: child,
                              ),
                            );
                          },
                          child: Padding(
                            padding: const EdgeInsets.only(bottom: 14),
                            child: RepaintBoundary(
                              child: _OrderCard(
                                order: order,
                                onTap: () => _openOrder(order),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
      ),
    );
  }
}

class _OrderCard extends StatelessWidget {
  const _OrderCard({
    required this.order,
    required this.onTap,
  });

  final Map<String, dynamic> order;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final statusInfo = resolveOrderStatus(order['status']?.toString());
    final total = OrdersService.totalPriceOf(order);
    final createdAt = OrdersService.createdAtOf(order);
    final receipt = OrdersService.receiptNumberOf(order);
    final orderId = OrdersService.shortIdOf(order);
    final restaurantName = OrdersService.restaurantNameOf(order);

    return ScaleOnTap(
      onTap: onTap,
      child: OrderSectionCard(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                OrderStatusBadge(info: statusInfo),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        'طلب #$orderId',
                        textAlign: TextAlign.right,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'ريسيت #$receipt',
                        textAlign: TextAlign.right,
                        style: const TextStyle(
                          color: Color(0xFF667085),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFF9F6F2),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: AppTheme.primary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Icon(
                      Icons.storefront_rounded,
                      color: AppTheme.primary,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      restaurantName,
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF101828),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            _InfoRow(
              icon: Icons.payments_outlined,
              label: 'الإجمالي',
              value: formatPrice(total),
            ),
            const SizedBox(height: 10),
            _InfoRow(
              icon: Icons.calendar_today_outlined,
              label: 'تاريخ الطلب',
              value: formatOrderDate(createdAt),
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
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
      children: [
        Icon(icon, size: 18, color: const Color(0xFF667085)),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            '$label: ',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Color(0xFF667085),
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            value,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
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

class _OrdersEmptyState extends StatelessWidget {
  const _OrdersEmptyState({
    super.key,
    required this.onOrderNow,
  });

  final VoidCallback onOrderNow;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 88,
              height: 88,
              decoration: BoxDecoration(
                color: const Color(0xFFFFF3E8),
                borderRadius: BorderRadius.circular(28),
              ),
              child: const Icon(
                Icons.receipt_long_rounded,
                size: 42,
                color: Color(0xFFFB8C00),
              ),
            ),
            const SizedBox(height: 18),
            const Text(
              'لا يوجد طلبات حتى الآن',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'ابدأ أول طلب وسيظهر هنا مع حالته وتفاصيله.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Color(0xFF667085)),
            ),
            const SizedBox(height: 18),
            ElevatedButton(
              onPressed: onOrderNow,
              child: const Text('اطلب الآن'),
            ),
          ],
        ),
      ),
    );
  }
}

class _OrdersErrorState extends StatelessWidget {
  const _OrdersErrorState({
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
              Icons.wifi_off_rounded,
              size: 46,
              color: Color(0xFF98A2B3),
            ),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontWeight: FontWeight.w700,
              ),
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
