import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../cart/cart_provider.dart';
import '../core/orders/order_status_utils.dart';
import '../core/orders/order_ui.dart';
import '../core/realtime/realtime_channel_controller.dart';
import '../core/services/error_logger.dart';
import '../core/theme/app_theme.dart';
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
  Timer? _orderRefreshDebounce;
  Timer? _itemsRefreshDebounce;

  bool _loading = true;
  String? _errorMessage;
  Map<String, dynamic>? _order;
  List<Map<String, dynamic>> _items = const [];
  int _loadDataRequestId = 0;
  int _loadItemsRequestId = 0;
  int _loadOrderOnlyRequestId = 0;
  bool _isLoadingItems = false;
  bool _pendingItemsRefresh = false;
  bool _isLoadingOrderOnly = false;
  bool _pendingOrderRefresh = false;

  @override
  void initState() {
    super.initState();

    _orderChannelController = RealtimeChannelController(
      client: _supabase,
      topicPrefix: 'tracking-order-${widget.orderId}',
      onSubscribed: (didReconnect) async {
        if (didReconnect) {
          await _loadData(forceRefresh: true);
        }
      },
    );

    _itemsChannelController = RealtimeChannelController(
      client: _supabase,
      topicPrefix: 'tracking-items-${widget.orderId}',
      onSubscribed: (didReconnect) async {
        if (didReconnect) {
          await _loadItems(forceRefresh: true);
        }
      },
    );

    _listenToRealtime();
    unawaited(_loadData(showLoader: true));
  }

  @override
  void dispose() {
    _orderRefreshDebounce?.cancel();
    _itemsRefreshDebounce?.cancel();
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

  Future<void> _loadData({
    bool showLoader = false,
    bool forceRefresh = false,
  }) async {
    final requestId = ++_loadDataRequestId;
    if (showLoader && mounted) {
      _applySnapshot(
        order: _order,
        items: _items,
        isLoading: true,
        errorMessage: null,
      );
    }

    final cart = CartProvider.maybeOf(context);

    try {
      final results = await Future.wait([
        OrdersService.getOrderById(
          widget.orderId,
          forceRefresh: forceRefresh,
        ),
        OrdersService.getOrderItems(
          widget.orderId,
          forceRefresh: forceRefresh,
        ),
      ]);

      final order = results[0] as Map<String, dynamic>?;
      final fetchedItems = results[1] as List<Map<String, dynamic>>;

      if (!mounted) {
        return;
      }
      if (requestId != _loadDataRequestId) {
        return;
      }

      if (order == null) {
        _applySnapshot(
          order: null,
          items: const [],
          isLoading: false,
          errorMessage: 'تعذر العثور على الطلب.',
        );
        return;
      }

      var normalizedItems = fetchedItems.isEmpty
          ? _itemsFromOrderPayload(order)
          : _sortedItems(fetchedItems);
      if (normalizedItems.isEmpty) {
        normalizedItems = await _loadItemsFromOrderColumn();
        if (!mounted || requestId != _loadDataRequestId) {
          return;
        }
      }

      cart?.syncOrderStatusFromRow(order);

      _applySnapshot(
        order: order,
        items: normalizedItems,
        isLoading: false,
        errorMessage: null,
      );
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'order_tracking_page.loadData',
        error: error,
        stack: stack,
      );
      if (!mounted) {
        return;
      }
      if (requestId != _loadDataRequestId) {
        return;
      }

      _applySnapshot(
        order: _order,
        items: _items,
        isLoading: false,
        errorMessage: 'تعذر تحميل بيانات التتبع.',
      );
    }
  }

  Future<void> _loadItems({bool forceRefresh = false}) async {
    if (_isLoadingItems) {
      _pendingItemsRefresh = true;
      return;
    }
    _isLoadingItems = true;
    final requestId = ++_loadItemsRequestId;
    try {
      final items = await OrdersService.getOrderItems(
        widget.orderId,
        forceRefresh: forceRefresh,
      );
      if (!mounted || requestId != _loadItemsRequestId) {
        return;
      }
      if (items.isEmpty) {
        var fallbackItems = const <Map<String, dynamic>>[];
        final order = _order;
        if (order != null) {
          fallbackItems = _itemsFromOrderPayload(order);
        }
        if (fallbackItems.isEmpty) {
          fallbackItems = await _loadItemsFromOrderColumn();
          if (!mounted || requestId != _loadItemsRequestId) {
            return;
          }
        }
        _applySnapshot(
          order: _order,
          items: fallbackItems,
          isLoading: _loading,
          errorMessage: _errorMessage,
        );
        return;
      }
      _applySnapshot(
        order: _order,
        items: _sortedItems(items),
        isLoading: _loading,
        errorMessage: _errorMessage,
      );
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'order_tracking_page.loadItems',
        error: error,
        stack: stack,
      );
    } finally {
      _isLoadingItems = false;
      if (_pendingItemsRefresh && mounted) {
        _pendingItemsRefresh = false;
        unawaited(_loadItems(forceRefresh: true));
      }
    }
  }

  Future<void> _loadOrderOnly({bool forceRefresh = true}) async {
    if (_isLoadingOrderOnly) {
      _pendingOrderRefresh = true;
      return;
    }
    _isLoadingOrderOnly = true;
    final requestId = ++_loadOrderOnlyRequestId;
    try {
      final order = await OrdersService.getOrderById(
        widget.orderId,
        forceRefresh: forceRefresh,
      );
      if (!mounted || requestId != _loadOrderOnlyRequestId || order == null) {
        return;
      }
      CartProvider.maybeOf(context)?.syncOrderStatusFromRow(order);
      if (_items.isEmpty) {
        _applySnapshot(
          order: order,
          items: _itemsFromOrderPayload(order),
          isLoading: _loading,
          errorMessage: _errorMessage,
        );
        return;
      }
      _applySnapshot(
        order: order,
        items: _items,
        isLoading: _loading,
        errorMessage: _errorMessage,
      );
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'order_tracking_page.loadOrderOnly',
        error: error,
        stack: stack,
      );
    } finally {
      _isLoadingOrderOnly = false;
      if (_pendingOrderRefresh && mounted) {
        _pendingOrderRefresh = false;
        unawaited(_loadOrderOnly(forceRefresh: true));
      }
    }
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

  void _applySnapshot({
    required Map<String, dynamic>? order,
    required List<Map<String, dynamic>> items,
    required bool isLoading,
    required String? errorMessage,
  }) {
    final nextOrder =
        _order != null && order != null && mapEquals(_order, order)
            ? _order
            : order;
    final nextItems = _reuseItems(items);
    final hasOrderChanged = !mapEquals(_order, nextOrder);
    final hasItemsChanged = !_sameItems(_items, nextItems);

    if (!hasOrderChanged &&
        !hasItemsChanged &&
        _loading == isLoading &&
        _errorMessage == errorMessage) {
      return;
    }

    setState(() {
      _order = nextOrder;
      _items = nextItems;
      _loading = isLoading;
      _errorMessage = errorMessage;
    });
  }

  List<Map<String, dynamic>> _reuseItems(List<Map<String, dynamic>> nextItems) {
    if (nextItems.isEmpty) {
      return const [];
    }

    final currentByKey = {
      for (final item in _items) _itemKey(item): item,
    };

    return nextItems.map((item) {
      final current = currentByKey[_itemKey(item)];
      if (current != null && mapEquals(current, item)) {
        return current;
      }
      return item;
    }).toList(growable: false);
  }

  bool _sameItems(
    List<Map<String, dynamic>> current,
    List<Map<String, dynamic>> next,
  ) {
    if (current.length != next.length) {
      return false;
    }

    for (var index = 0; index < current.length; index++) {
      if (!identical(current[index], next[index])) {
        return false;
      }
    }

    return true;
  }

  String _itemKey(Map<String, dynamic> item) {
    final itemId = OrdersService.itemIdOf(item);
    if (itemId.isNotEmpty) {
      return itemId;
    }

    return '${OrdersService.itemNameOf(item)}-'
        '${OrdersService.quantityOfItem(item)}-'
        '${OrdersService.itemPriceOf(item)}-'
        '${OrdersService.createdAtOf(item).microsecondsSinceEpoch}';
  }

  List<Map<String, dynamic>> _itemsFromOrderPayload(
      Map<String, dynamic> order) {
    final dynamic payload = order['items'];
    if (payload == null) {
      return const [];
    }

    List<dynamic> rawItems;
    if (payload is List) {
      rawItems = payload;
    } else if (payload is String) {
      dynamic decoded;
      try {
        decoded = jsonDecode(payload);
      } catch (_) {
        return const [];
      }
      if (decoded is! List) {
        return const [];
      }
      rawItems = decoded;
    } else {
      return const [];
    }

    final normalized = <Map<String, dynamic>>[];
    for (var i = 0; i < rawItems.length; i++) {
      final raw = rawItems[i];
      if (raw is! Map) {
        continue;
      }
      final item = Map<String, dynamic>.from(raw);
      final qty = (OrdersService.toDouble(
                      item['qty'] ?? item['quantity'] ?? item['count'])
                  ?.round() ??
              1)
          .clamp(1, 9999);
      final price = OrdersService.toDouble(
            item['price'] ?? item['unit_price'] ?? item['line_price'],
          ) ??
          0;
      final name = (item['item_name'] ?? item['name'] ?? 'عنصر').toString();
      normalized.add({
        'item_name': name,
        'qty': qty,
        'price': price,
        'created_at': item['created_at'] ??
            DateTime.fromMillisecondsSinceEpoch(i).toIso8601String(),
      });
    }

    return _sortedItems(normalized);
  }

  Future<List<Map<String, dynamic>>> _loadItemsFromOrderColumn() async {
    try {
      final row = await _supabase
          .from('orders')
          .select('items')
          .eq('id', widget.orderId)
          .maybeSingle();
      if (row == null) {
        return const [];
      }
      return _itemsFromOrderPayload(Map<String, dynamic>.from(row));
    } catch (_) {
      return const [];
    }
  }

  void _handleOrderChange(PostgresChangePayload payload) {
    if (payload.eventType == PostgresChangeEvent.delete) {
      if (!mounted) {
        return;
      }
      _applySnapshot(
        order: {
          ...?_order,
          'status': 'cancelled',
        },
        items: _items,
        isLoading: _loading,
        errorMessage: _errorMessage,
      );
      return;
    }

    _scheduleOrderRefresh();
  }

  void _handleItemsChange(PostgresChangePayload payload) {
    switch (payload.eventType) {
      case PostgresChangeEvent.delete:
      case PostgresChangeEvent.insert:
      case PostgresChangeEvent.update:
        _scheduleItemsRefresh();
        break;
      case PostgresChangeEvent.all:
        break;
    }
  }

  void _scheduleOrderRefresh() {
    _orderRefreshDebounce?.cancel();
    final debounceDuration = kIsWeb
        ? const Duration(milliseconds: 420)
        : const Duration(milliseconds: 250);
    _orderRefreshDebounce = Timer(
      debounceDuration,
      () {
        if (!mounted) {
          return;
        }
        unawaited(_loadOrderOnly(forceRefresh: true));
      },
    );
  }

  void _scheduleItemsRefresh() {
    _itemsRefreshDebounce?.cancel();
    final debounceDuration = kIsWeb
        ? const Duration(milliseconds: 420)
        : const Duration(milliseconds: 250);
    _itemsRefreshDebounce = Timer(
      debounceDuration,
      () {
        if (!mounted) {
          return;
        }
        unawaited(_loadItems(forceRefresh: true));
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final order = _order;
    final switcherDuration =
        kIsWeb ? Duration.zero : const Duration(milliseconds: 220);

    return Scaffold(
      backgroundColor: const Color(0xFFF6F7FB),
      appBar: AppBar(
        title: const Text('تتبع الطلب'),
        centerTitle: true,
      ),
      body: AnimatedSwitcher(
        duration: switcherDuration,
        child: _loading
            ? const Center(
                key: ValueKey('loading'),
                child: CircularProgressIndicator(),
              )
            : order == null
                ? _TrackingErrorState(
                    key: const ValueKey('error'),
                    message: _errorMessage ?? 'تعذر تحميل التتبع.',
                    onRetry: () =>
                        _loadData(showLoader: true, forceRefresh: true),
                  )
                : RefreshIndicator(
                    key: const ValueKey('content'),
                    onRefresh: () => _loadData(forceRefresh: true),
                    child: ListView(
                      physics: AppTheme.bouncingScrollPhysics,
                      cacheExtent: 540,
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                      children: [
                        RepaintBoundary(child: _TrackingRouteMap(order: order)),
                        const SizedBox(height: 16),
                        _AnimatedTrackingSection(
                          delay: const Duration(milliseconds: 40),
                          child: _TrackingOrderInfoCard(
                            order: order,
                            items: _items,
                          ),
                        ),
                        const SizedBox(height: 16),
                        _AnimatedTrackingSection(
                          delay: const Duration(milliseconds: 80),
                          child: _TrackingStatusCard(
                            status: order['status']?.toString(),
                          ),
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
                  AppTheme.platformPageRoute(
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

class _AnimatedTrackingSection extends StatelessWidget {
  const _AnimatedTrackingSection({
    required this.child,
    this.delay = Duration.zero,
  });

  final Widget child;
  final Duration delay;

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) {
      return child;
    }
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: AppTheme.sectionTransitionDuration + delay,
      curve: AppTheme.emphasizedCurve,
      child: child,
      builder: (context, value, animatedChild) {
        return Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(0, (1 - value) * 16),
            child: animatedChild,
          ),
        );
      },
    );
  }
}

class _TrackingOrderInfoCard extends StatelessWidget {
  const _TrackingOrderInfoCard({
    required this.order,
    required this.items,
  });

  final Map<String, dynamic> order;
  final List<Map<String, dynamic>> items;

  @override
  Widget build(BuildContext context) {
    final animationDuration =
        kIsWeb ? Duration.zero : AppTheme.sectionTransitionDuration;
    final customerName = OrdersService.customerNameOf(order);
    final customerPhone = OrdersService.customerPhoneOf(order) ?? '--';
    final address = _composeAddress(order);
    final itemRows = items
        .map((item) => _OrderItemRow(key: ValueKey(_itemKey(item)), item: item))
        .toList(growable: false);

    return OrderSectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'معلومات الطلب',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 14),
          _TrackingMetaRow(
            icon: Icons.location_on_outlined,
            label: 'عنوان التوصيل',
            value: address,
          ),
          const SizedBox(height: 10),
          _TrackingMetaRow(
            icon: Icons.person_outline,
            label: 'اسم العميل',
            value: customerName,
          ),
          const SizedBox(height: 10),
          _TrackingMetaRow(
            icon: Icons.phone_android_outlined,
            label: 'رقم العميل',
            value: customerPhone,
          ),
          const SizedBox(height: 14),
          const Divider(height: 1),
          const SizedBox(height: 14),
          const Text(
            'الأصناف المطلوبة',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 10),
          const _ItemsHeaderRow(),
          const SizedBox(height: 8),
          AnimatedSize(
            duration: animationDuration,
            curve: AppTheme.emphasizedCurve,
            child: items.isEmpty
                ? const Align(
                    alignment: Alignment.centerRight,
                    child: Text(
                      'لا توجد أصناف مرتبطة بهذا الطلب.',
                      style: TextStyle(color: Color(0xFF667085)),
                    ),
                  )
                : Column(children: itemRows),
          ),
        ],
      ),
    );
  }

  static String _composeAddress(Map<String, dynamic> order) {
    final baseAddress = OrdersService.addressOf(order).trim();
    final houseNumber = (order['house_number'] ?? '').toString().trim();
    if (houseNumber.isEmpty) {
      return baseAddress;
    }
    return '$baseAddress - رقم البيت: $houseNumber';
  }

  static String _itemKey(Map<String, dynamic> item) {
    final itemId = OrdersService.itemIdOf(item);
    if (itemId.isNotEmpty) {
      return itemId;
    }

    return '${OrdersService.itemNameOf(item)}-'
        '${OrdersService.quantityOfItem(item)}-'
        '${OrdersService.itemPriceOf(item)}-'
        '${OrdersService.createdAtOf(item).microsecondsSinceEpoch}';
  }
}

class _ItemsHeaderRow extends StatelessWidget {
  const _ItemsHeaderRow();

  @override
  Widget build(BuildContext context) {
    const headerStyle = TextStyle(
      color: Color(0xFF667085),
      fontWeight: FontWeight.w700,
      fontSize: 12,
    );

    return Row(
      children: const [
        Expanded(
          flex: 3,
          child: Text(
            'السعر',
            style: headerStyle,
            textAlign: TextAlign.start,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        Expanded(
          flex: 2,
          child: Text(
            'الكمية',
            style: headerStyle,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        Expanded(
          flex: 5,
          child: Text('الصنف', style: headerStyle, textAlign: TextAlign.end),
        ),
      ],
    );
  }
}

class _OrderItemRow extends StatelessWidget {
  const _OrderItemRow({
    super.key,
    required this.item,
  });

  final Map<String, dynamic> item;

  @override
  Widget build(BuildContext context) {
    final qty = OrdersService.quantityOfItem(item);
    final price = OrdersService.itemPriceOf(item);

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Text(
              formatPrice(price),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFF475467),
                fontWeight: FontWeight.w700,
              ),
              textAlign: TextAlign.start,
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              '$qty',
              style: const TextStyle(
                color: Color(0xFF344054),
                fontWeight: FontWeight.w700,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          Expanded(
            flex: 5,
            child: Text(
              OrdersService.itemNameOf(item),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFF101828),
                fontWeight: FontWeight.w700,
                height: 1.4,
              ),
              textAlign: TextAlign.end,
            ),
          ),
        ],
      ),
    );
  }
}

class _TrackingStatusCard extends StatelessWidget {
  const _TrackingStatusCard({
    required this.status,
  });

  final String? status;

  @override
  Widget build(BuildContext context) {
    final animationDuration =
        kIsWeb ? Duration.zero : AppTheme.sectionTransitionDuration;
    final statusInfo = resolveOrderStatus(status);
    final normalized = normalizeOrderStatus(status);
    final progress = _statusProgress(normalized);
    final rawStatus = (status ?? '').trim();
    const stages = [
      ('تم التأكيد', 0.25),
      ('في الطريق', 0.60),
      ('تم التسليم', 0.85),
      ('اكتمل', 1.0),
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
          AnimatedSwitcher(
            duration: animationDuration,
            switchInCurve: AppTheme.emphasizedCurve,
            switchOutCurve: Curves.easeInCubic,
            child: Text(
              statusInfo.text,
              key: ValueKey(statusInfo.text),
              style: TextStyle(
                color: statusInfo.color,
                fontWeight: FontWeight.w800,
                fontSize: 18,
              ),
            ),
          ),
          AnimatedSize(
            duration: animationDuration,
            curve: AppTheme.emphasizedCurve,
            child: rawStatus.isEmpty
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      rawStatus,
                      style: const TextStyle(
                        color: Color(0xFF667085),
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                      ),
                    ),
                  ),
          ),
          const SizedBox(height: 14),
          _TrackingPipeProgress(
            value: progress,
            color: statusInfo.color,
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: stages
                .map(
                  (stage) => _ProgressHint(
                    text: stage.$1,
                    active: progress >= stage.$2,
                  ),
                )
                .toList(growable: false),
          ),
        ],
      ),
    );
  }

  static double _statusProgress(String normalized) {
    switch (normalized) {
      case 'accepted':
      case 'confirmed':
        return 0.25;
      case 'on_way':
      case 'on_the_way':
      case 'on_theway':
      case 'onway':
      case 'arrived':
        return 0.60;
      case 'delivered':
        return 0.85;
      case 'completed':
        return 1.0;
      default:
        return 0.08;
    }
  }
}

class _TrackingPipeProgress extends StatelessWidget {
  const _TrackingPipeProgress({
    required this.value,
    required this.color,
  });

  final double value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final clampedValue = value.clamp(0.0, 1.0);
    if (kIsWeb) {
      return _TrackingPipeBar(
        value: clampedValue,
        color: color,
      );
    }

    return TweenAnimationBuilder<double>(
      duration: const Duration(milliseconds: 650),
      curve: Curves.easeOutCubic,
      tween: Tween<double>(end: clampedValue),
      builder: (context, animatedValue, _) {
        return _TrackingPipeBar(
          value: animatedValue,
          color: color,
        );
      },
    );
  }
}

class _TrackingPipeBar extends StatelessWidget {
  const _TrackingPipeBar({
    required this.value,
    required this.color,
  });

  final double value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: Stack(
        children: [
          Container(
            height: 16,
            width: double.infinity,
            color: const Color(0xFFDDE3EA),
          ),
          FractionallySizedBox(
            widthFactor: value,
            child: Container(
              height: 16,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    color.withValues(alpha: 0.9),
                    color,
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProgressHint extends StatelessWidget {
  const _ProgressHint({
    required this.text,
    required this.active,
  });

  final String text;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final animationDuration =
        kIsWeb ? Duration.zero : AppTheme.microInteractionDuration;
    return AnimatedContainer(
      duration: animationDuration,
      curve: AppTheme.emphasizedCurve,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: active
            ? AppTheme.primary.withValues(alpha: 0.12)
            : const Color(0xFFF2F4F7),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: active ? AppTheme.primary : const Color(0xFF667085),
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _TrackingRouteMap extends StatefulWidget {
  const _TrackingRouteMap({
    required this.order,
  });

  final Map<String, dynamic> order;

  @override
  State<_TrackingRouteMap> createState() => _TrackingRouteMapState();
}

class _TrackingRouteMapState extends State<_TrackingRouteMap> {
  final MapController _mapController = MapController();
  late final ValueNotifier<List<Marker>> _markersNotifier =
      ValueNotifier<List<Marker>>(const []);
  late final ValueNotifier<List<Polyline>> _polylinesNotifier =
      ValueNotifier<List<Polyline>>(const []);

  _TrackingRouteSnapshot? _snapshot;
  Widget? _mapShell;

  @override
  void initState() {
    super.initState();
    _syncSnapshot(widget.order, moveMap: false);
  }

  @override
  void didUpdateWidget(covariant _TrackingRouteMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncSnapshot(widget.order);
  }

  @override
  void dispose() {
    _markersNotifier.dispose();
    _polylinesNotifier.dispose();
    super.dispose();
  }

  void _syncSnapshot(
    Map<String, dynamic> order, {
    bool moveMap = true,
  }) {
    final previous = _snapshot;
    final next = _TrackingRouteSnapshot.fromOrder(order);
    if (next == previous) {
      return;
    }

    _snapshot = next;
    if (next == null) {
      return;
    }

    _ensureMapShell(next);
    final routeChanged = previous == null ||
        !_samePoint(previous.restaurantPoint, next.restaurantPoint) ||
        !_samePoint(previous.customerPoint, next.customerPoint);

    if (routeChanged) {
      _polylinesNotifier.value = [
        Polyline(
          points: [next.restaurantPoint, next.customerPoint],
          strokeWidth: 5,
          color: const Color(0xFF1565C0),
        ),
      ];
    }

    _markersNotifier.value = _buildMarkers(next);

    if (routeChanged && moveMap) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _mapController.move(next.center, 13);
        }
      });
    }
  }

  void _ensureMapShell(_TrackingRouteSnapshot snapshot) {
    _mapShell ??= _TrackingRouteMapShell(
      mapController: _mapController,
      initialCenter: snapshot.center,
      markersListenable: _markersNotifier,
      polylinesListenable: _polylinesNotifier,
    );
  }

  List<Marker> _buildMarkers(_TrackingRouteSnapshot snapshot) {
    final markers = <Marker>[
      Marker(
        point: snapshot.restaurantPoint,
        width: 42,
        height: 42,
        child: const _MapMarker(
          icon: Icons.storefront_rounded,
          color: Color(0xFF1E88E5),
        ),
      ),
      Marker(
        point: snapshot.customerPoint,
        width: 42,
        height: 42,
        child: const _MapMarker(
          icon: Icons.location_on_rounded,
          color: Color(0xFF2E7D32),
        ),
      ),
    ];

    final driverPoint = snapshot.driverPoint;
    if (driverPoint != null) {
      markers.add(
        Marker(
          point: driverPoint,
          width: 52,
          height: 52,
          child: _DriverMarker(
            angle: _bearingRadians(driverPoint, snapshot.customerPoint),
          ),
        ),
      );
    }

    return markers;
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    if (snapshot == null) {
      return const _TrackingMapUnavailable();
    }

    _ensureMapShell(snapshot);
    return RepaintBoundary(child: _mapShell!);
  }

  static bool _samePoint(LatLng first, LatLng second) {
    return first.latitude == second.latitude &&
        first.longitude == second.longitude;
  }

  static double _bearingRadians(LatLng from, LatLng to) {
    final lat1 = from.latitude * (math.pi / 180);
    final lat2 = to.latitude * (math.pi / 180);
    final dLon = (to.longitude - from.longitude) * (math.pi / 180);

    final y = math.sin(dLon) * math.cos(lat2);
    final x = math.cos(lat1) * math.sin(lat2) -
        math.sin(lat1) * math.cos(lat2) * math.cos(dLon);

    return math.atan2(y, x);
  }
}

class _TrackingRouteMapShell extends StatelessWidget {
  const _TrackingRouteMapShell({
    required this.mapController,
    required this.initialCenter,
    required this.markersListenable,
    required this.polylinesListenable,
  });

  final MapController mapController;
  final LatLng initialCenter;
  final ValueListenable<List<Marker>> markersListenable;
  final ValueListenable<List<Polyline>> polylinesListenable;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: SizedBox(
        height: 300,
        child: FlutterMap(
          mapController: mapController,
          options: MapOptions(
            initialCenter: initialCenter,
            initialZoom: 13,
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.pinchZoom | InteractiveFlag.drag,
            ),
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'restaurant_customer',
            ),
            ValueListenableBuilder<List<Polyline>>(
              valueListenable: polylinesListenable,
              builder: (context, polylines, _) {
                return PolylineLayer(polylines: polylines);
              },
            ),
            ValueListenableBuilder<List<Marker>>(
              valueListenable: markersListenable,
              builder: (context, markers, _) {
                return MarkerLayer(markers: markers);
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _TrackingRouteSnapshot {
  const _TrackingRouteSnapshot({
    required this.restaurantPoint,
    required this.customerPoint,
    required this.center,
    this.driverPoint,
  });

  final LatLng restaurantPoint;
  final LatLng customerPoint;
  final LatLng center;
  final LatLng? driverPoint;

  static _TrackingRouteSnapshot? fromOrder(Map<String, dynamic> order) {
    final restaurantLat = OrdersService.restaurantLatOf(order);
    final restaurantLng = OrdersService.restaurantLngOf(order);
    final customerLat = OrdersService.customerLatOf(order);
    final customerLng = OrdersService.customerLngOf(order);
    if (restaurantLat == null ||
        restaurantLng == null ||
        customerLat == null ||
        customerLng == null) {
      return null;
    }

    final restaurantPoint = LatLng(restaurantLat, restaurantLng);
    final customerPoint = LatLng(customerLat, customerLng);
    final driverLat = OrdersService.driverLatOf(order);
    final driverLng = OrdersService.driverLngOf(order);

    return _TrackingRouteSnapshot(
      restaurantPoint: restaurantPoint,
      customerPoint: customerPoint,
      center: LatLng(
        (restaurantPoint.latitude + customerPoint.latitude) / 2,
        (restaurantPoint.longitude + customerPoint.longitude) / 2,
      ),
      driverPoint: driverLat != null && driverLng != null
          ? LatLng(driverLat, driverLng)
          : null,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    return other is _TrackingRouteSnapshot &&
        restaurantPoint.latitude == other.restaurantPoint.latitude &&
        restaurantPoint.longitude == other.restaurantPoint.longitude &&
        customerPoint.latitude == other.customerPoint.latitude &&
        customerPoint.longitude == other.customerPoint.longitude &&
        driverPoint?.latitude == other.driverPoint?.latitude &&
        driverPoint?.longitude == other.driverPoint?.longitude;
  }

  @override
  int get hashCode => Object.hash(
        restaurantPoint.latitude,
        restaurantPoint.longitude,
        customerPoint.latitude,
        customerPoint.longitude,
        driverPoint?.latitude,
        driverPoint?.longitude,
      );
}

class _TrackingMapUnavailable extends StatelessWidget {
  const _TrackingMapUnavailable();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 240,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xFFE4E7EC)),
      ),
      child: const Center(
        child: Text(
          'لا يمكن عرض مسار التوصيل حالياً.',
          style: TextStyle(
            color: Color(0xFF667085),
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _DriverMarker extends StatelessWidget {
  const _DriverMarker({
    required this.angle,
  });

  final double angle;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: Color(0x22000000),
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Center(
        child: Transform.rotate(
          angle: angle,
          child: const Icon(
            Icons.navigation_rounded,
            color: Color(0xFFFB8C00),
            size: 28,
          ),
        ),
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
      decoration: const BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: Color(0x22000000),
            blurRadius: 10,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: Icon(icon, color: color, size: 22),
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
        Flexible(
          child: Text(
            '$label: ',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Color(0xFF667085),
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            value,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Color(0xFF101828),
              fontWeight: FontWeight.w700,
              height: 1.4,
            ),
          ),
        ),
      ],
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
