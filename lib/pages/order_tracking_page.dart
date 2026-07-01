import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../cart/cart_provider.dart';
import '../core/orders/delivery_confirmation_ui.dart';
import '../core/orders/order_status_utils.dart';
import '../core/orders/order_ui.dart';
import '../core/realtime/realtime_channel_controller.dart';
import '../core/services/error_logger.dart';
import '../core/stability/stability_logger.dart';
import '../core/theme/app_theme.dart';
import '../core/ui/app_snackbar.dart';
import '../services/orders_service.dart';
import '../services/session_manager.dart';
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
  late final RealtimeChannelController _driverPresenceChannelController;
  Timer? _orderRefreshDebounce;
  Timer? _itemsRefreshDebounce;
  Timer? _driverPresenceRefreshDebounce;

  bool _loading = true;
  String? _errorMessage;
  Map<String, dynamic>? _order;
  Map<String, dynamic>? _driverPresence;
  List<Map<String, dynamic>> _items = const [];
  int _loadDataRequestId = 0;
  int _loadItemsRequestId = 0;
  int _loadOrderOnlyRequestId = 0;
  int _loadDriverPresenceRequestId = 0;
  bool _isLoadingItems = false;
  bool _pendingItemsRefresh = false;
  bool _isLoadingOrderOnly = false;
  bool _pendingOrderRefresh = false;
  bool _isLoadingDriverPresence = false;
  bool _pendingDriverPresenceRefresh = false;
  bool _deliveryConfirmationDialogOpen = false;
  String? _lastPromptedDeliveryConfirmationKey;
  String? _driverPresenceDriverId;

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

    _driverPresenceChannelController = RealtimeChannelController(
      client: _supabase,
      topicPrefix: 'tracking-driver-${widget.orderId}',
      onSubscribed: (didReconnect) async {
        if (didReconnect) {
          await _loadDriverPresence(forceRefresh: true);
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
    _driverPresenceRefreshDebounce?.cancel();
    unawaited(_orderChannelController.dispose());
    unawaited(_itemsChannelController.dispose());
    unawaited(_driverPresenceChannelController.dispose());
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

  Map<String, dynamic>? get _presentedOrder {
    return _mergeDriverPresenceIntoOrder(_order);
  }

  Map<String, dynamic>? _mergeDriverPresenceIntoOrder(
    Map<String, dynamic>? order,
  ) {
    if (order == null) {
      return null;
    }

    final presence = _driverPresence;
    if (presence == null) {
      return order;
    }

    final orderDriverId = OrdersService.driverIdOf(order);
    final presenceDriverId = presence['driver_id']?.toString().trim() ?? '';
    if (orderDriverId == null ||
        orderDriverId.isEmpty ||
        presenceDriverId != orderDriverId) {
      return order;
    }

    final lat = OrdersService.toDouble(presence['lat']);
    final lng = OrdersService.toDouble(presence['lng']);
    return {
      ...order,
      if (lat != null) 'driver_lat': lat,
      if (lng != null) 'driver_lng': lng,
      if (lat != null || lng != null)
        'driver_location': <String, dynamic>{
          if (lat != null) 'lat': lat,
          if (lng != null) 'lng': lng,
        },
      'driver_presence': presence,
      if (presence['updated_at'] != null)
        'driver_presence_updated_at': presence['updated_at'],
      if (presence['heading'] != null) 'driver_heading': presence['heading'],
      if (presence['speed_kmh'] != null)
        'driver_speed_kmh': presence['speed_kmh'],
      if (presence['accuracy_m'] != null)
        'driver_accuracy_m': presence['accuracy_m'],
    };
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
      if (!mounted || requestId != _loadOrderOnlyRequestId) {
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
    final previousOrder = _order;
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

    unawaited(_syncDriverPresenceSubscription(nextOrder));
    _handleDeliveryConfirmationStateChange(previousOrder, nextOrder);
  }

  Future<void> _syncDriverPresenceSubscription(
    Map<String, dynamic>? order,
  ) async {
    final driverId = OrdersService.driverIdOf(order ?? const {})?.trim();
    if (driverId == null || driverId.isEmpty) {
      _driverPresenceDriverId = null;
      _driverPresenceRefreshDebounce?.cancel();
      await _driverPresenceChannelController.clear();
      if (_driverPresence != null && mounted) {
        setState(() {
          _driverPresence = null;
        });
      }
      return;
    }

    final didDriverChange = _driverPresenceDriverId != driverId;
    _driverPresenceDriverId = driverId;
    if (didDriverChange) {
      if (_driverPresence != null && mounted) {
        setState(() {
          _driverPresence = null;
        });
      }
      _driverPresenceChannelController.subscribe(
        (client, channelName) {
          return client.channel(channelName).onPostgresChanges(
                event: PostgresChangeEvent.all,
                schema: 'public',
                table: 'driver_presence',
                filter: PostgresChangeFilter(
                  type: PostgresChangeFilterType.eq,
                  column: 'driver_id',
                  value: driverId,
                ),
                callback: _handleDriverPresenceChange,
              );
        },
        resetConnectionState: true,
      );
    }

    await _loadDriverPresence(forceRefresh: didDriverChange);
  }

  void _handleDriverPresenceChange(PostgresChangePayload payload) {
    if (payload.eventType == PostgresChangeEvent.delete) {
      if (_driverPresence == null || !mounted) {
        return;
      }
      setState(() {
        _driverPresence = null;
      });
      return;
    }
    _scheduleDriverPresenceRefresh();
  }

  void _scheduleDriverPresenceRefresh() {
    _driverPresenceRefreshDebounce?.cancel();
    final debounceDuration = kIsWeb
        ? const Duration(milliseconds: 420)
        : const Duration(milliseconds: 180);
    _driverPresenceRefreshDebounce = Timer(
      debounceDuration,
      () {
        if (!mounted) {
          return;
        }
        unawaited(_loadDriverPresence(forceRefresh: true));
      },
    );
  }

  Future<void> _loadDriverPresence({bool forceRefresh = false}) async {
    final driverId = _driverPresenceDriverId;
    if (driverId == null || driverId.isEmpty) {
      return;
    }
    if (_isLoadingDriverPresence) {
      _pendingDriverPresenceRefresh = true;
      return;
    }
    _isLoadingDriverPresence = true;
    final requestId = ++_loadDriverPresenceRequestId;
    try {
      final row = await SessionManager.instance
          .runWithValidSession<Map<String, dynamic>?>(() async {
        final response = await _supabase
            .from('driver_presence')
            .select('*')
            .eq('driver_id', driverId)
            .order('updated_at', ascending: false)
            .limit(1)
            .maybeSingle();
        if (response == null) {
          return null;
        }
        return Map<String, dynamic>.from(response);
      }, requireSession: true);
      if (!mounted ||
          requestId != _loadDriverPresenceRequestId ||
          driverId != _driverPresenceDriverId) {
        return;
      }

      if (mapEquals(_driverPresence, row)) {
        return;
      }

      setState(() {
        _driverPresence = row;
      });
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'order_tracking_page.loadDriverPresence',
        error: error,
        stack: stack,
      );
    } finally {
      _isLoadingDriverPresence = false;
      if (_pendingDriverPresenceRefresh && mounted) {
        _pendingDriverPresenceRefresh = false;
        unawaited(_loadDriverPresence(forceRefresh: forceRefresh));
      }
    }
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

  void _handleDeliveryConfirmationStateChange(
    Map<String, dynamic>? previousOrder,
    Map<String, dynamic>? nextOrder,
  ) {
    if (nextOrder == null) {
      _closeDeliveryConfirmationDialogIfOpen();
      return;
    }

    final previousStatus = previousOrder == null
        ? ''
        : OrdersService.normalizedStatusOf(
            previousOrder,
          );
    final nextStatus = OrdersService.normalizedStatusOf(nextOrder);

    if (nextStatus == awaitingCustomerConfirmationStatus) {
      if (previousStatus != awaitingCustomerConfirmationStatus &&
          ModalRoute.of(context)?.isCurrent == true) {
        StabilityLogger.deliveryConfirmation(
          'Awaiting Customer Confirmation order=${OrdersService.idOf(nextOrder)} '
          'authoritative_state_version=${OrdersService.authoritativeStateVersionOf(nextOrder) ?? '-'} '
          'order_version=${OrdersService.orderVersionOf(nextOrder) ?? '-'}',
        );
      }
      _scheduleDeliveryConfirmationDialog(nextOrder);
      return;
    }

    if (previousStatus == awaitingCustomerConfirmationStatus) {
      final shouldNotifyCompletion = _deliveryConfirmationDialogOpen ||
          ModalRoute.of(context)?.isCurrent == true;
      _closeDeliveryConfirmationDialogIfOpen();
      if (nextStatus == 'completed' && shouldNotifyCompletion) {
        StabilityLogger.deliveryConfirmation(
          'Delivery Completed order=${OrdersService.idOf(nextOrder)} '
          'authoritative_state_version=${OrdersService.authoritativeStateVersionOf(nextOrder) ?? '-'} '
          'order_version=${OrdersService.orderVersionOf(nextOrder) ?? '-'}',
        );
        AppSnackBar.show(
          context,
          message: 'تم تأكيد استلام الطلب بنجاح',
        );
      }
    }
  }

  void _scheduleDeliveryConfirmationDialog(
    Map<String, dynamic> order, {
    bool force = false,
  }) {
    if (!mounted ||
        ModalRoute.of(context)?.isCurrent != true ||
        !isAwaitingCustomerConfirmationStatus(order['status'])) {
      return;
    }

    final promptKey = deliveryConfirmationStateKey(order);
    if (!force && _lastPromptedDeliveryConfirmationKey == promptKey) {
      return;
    }
    _lastPromptedDeliveryConfirmationKey = promptKey;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final currentOrder = _order;
      if (currentOrder == null ||
          !isAwaitingCustomerConfirmationStatus(currentOrder['status'])) {
        return;
      }
      if (!force && deliveryConfirmationStateKey(currentOrder) != promptKey) {
        return;
      }
      unawaited(_openDeliveryConfirmationDialog(currentOrder));
    });
  }

  Future<void> _openDeliveryConfirmationDialog(
    Map<String, dynamic> order,
  ) async {
    if (_deliveryConfirmationDialogOpen ||
        !isAwaitingCustomerConfirmationStatus(order['status'])) {
      return;
    }

    _deliveryConfirmationDialogOpen = true;
    try {
      await showDeliveryConfirmationDialog(
        context: context,
        order: order,
        onConfirm: confirmDeliveryReceived,
        onContactDriver: () => unawaited(_callDriver()),
      );
    } finally {
      _deliveryConfirmationDialogOpen = false;
    }
  }

  void _closeDeliveryConfirmationDialogIfOpen() {
    if (!_deliveryConfirmationDialogOpen || !mounted) {
      return;
    }
    _deliveryConfirmationDialogOpen = false;
    Navigator.of(context).pop();
  }

  Future<void> confirmDeliveryReceived() async {
    final order = _order;
    if (order == null ||
        !isAwaitingCustomerConfirmationStatus(order['status'])) {
      throw Exception('لا يمكن تأكيد الاستلام على الحالة الحالية للطلب.');
    }

    await OrdersService.confirmDeliveryReceived(order);
  }

  Future<void> _callPhone(
    String? phone, {
    required String unavailableMessage,
  }) async {
    final normalizedPhone = phone?.trim() ?? '';
    if (normalizedPhone.isEmpty) {
      AppSnackBar.show(context, message: unavailableMessage);
      return;
    }

    final uri = Uri.parse('tel:$normalizedPhone');
    final canLaunch = await canLaunchUrl(uri);
    if (!mounted) {
      return;
    }
    if (!canLaunch) {
      AppSnackBar.show(context, message: unavailableMessage);
      return;
    }
    await launchUrl(uri);
  }

  Future<void> _callRestaurant(String phone) {
    return _callPhone(
      phone,
      unavailableMessage: 'رقم المطعم غير متوفر حاليًا.',
    );
  }

  Future<void> _callDriver() {
    final order = _presentedOrder ?? _order;
    return _callPhone(
      order == null ? null : OrdersService.driverPhoneOf(order),
      unavailableMessage: 'رقم السائق غير متوفر حاليًا.',
    );
  }

  void _openChatPage() {
    Navigator.push(
      context,
      AppTheme.platformPageRoute(
        builder: (_) => OrderChatPage(orderId: widget.orderId),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final order = _presentedOrder;
    final switcherDuration =
        kIsWeb ? Duration.zero : const Duration(milliseconds: 220);
    final restaurantPhone =
        order == null ? null : OrdersService.restaurantPhoneOf(order);
    final normalizedStatus =
        order == null ? '' : normalizeOrderStatus(order['status']?.toString());
    final showDriverRoute = normalizedStatus == 'delivered';

    return Scaffold(
      backgroundColor: const Color(0xFFF6F7FB),
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leadingWidth: 72,
        title: const Text('تتبع الطلب'),
        centerTitle: true,
        leading: Builder(
          builder: (scaffoldContext) {
            final tooltip =
                MaterialLocalizations.of(scaffoldContext).openAppDrawerTooltip;
            return IconButton(
              key: const Key('tracking-drawer-menu-button'),
              tooltip: tooltip,
              icon: const Icon(
                Icons.menu_rounded,
                size: 28,
              ),
              onPressed: () => Scaffold.of(scaffoldContext).openDrawer(),
            );
          },
        ),
        actions: [
          if (Navigator.of(context).canPop())
            IconButton(
              tooltip: MaterialLocalizations.of(context).backButtonTooltip,
              icon: const BackButtonIcon(),
              onPressed: () => Navigator.maybePop(context),
            ),
        ],
      ),
      drawer: _TrackingDrawer(
        order: order,
        onOpenChat: order == null ? null : _openChatPage,
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
                        _AnimatedTrackingSection(
                          delay: const Duration(milliseconds: 40),
                          child: _TrackingStatusCard(
                            order: order,
                          ),
                        ),
                        if (showDriverRoute) ...[
                          const SizedBox(height: 16),
                          _AnimatedTrackingSection(
                            delay: const Duration(milliseconds: 55),
                            child: _TrackingLiveRouteCard(order: order),
                          ),
                        ],
                        if (isAwaitingCustomerConfirmationStatus(
                          order['status'],
                        )) ...[
                          const SizedBox(height: 16),
                          _AnimatedTrackingSection(
                            delay: const Duration(milliseconds: 60),
                            child: DeliveryConfirmationBanner(
                              onOpenConfirmation: () =>
                                  _scheduleDeliveryConfirmationDialog(
                                order,
                                force: true,
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                        ],
                        _AnimatedTrackingSection(
                          delay: const Duration(milliseconds: 80),
                          child: _TrackingOrderSummaryCard(order: order),
                        ),
                        const SizedBox(height: 16),
                        _AnimatedTrackingSection(
                          delay: const Duration(milliseconds: 120),
                          child: _TrackingRestaurantCard(
                            order: order,
                            onCall: _callRestaurant,
                          ),
                        ),
                        const SizedBox(height: 16),
                        _AnimatedTrackingSection(
                          delay: const Duration(milliseconds: 160),
                          child: _TrackingAddressCard(order: order),
                        ),
                        const SizedBox(height: 16),
                        _AnimatedTrackingSection(
                          delay: const Duration(milliseconds: 200),
                          child: _TrackingItemsCard(
                            items: _items,
                            totalPrice: OrdersService.totalPriceOf(order),
                            deliveryCost: OrdersService.deliveryCostOf(order),
                          ),
                        ),
                      ],
                    ),
                  ),
      ),
      floatingActionButton: order == null
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (restaurantPhone != null && restaurantPhone.isNotEmpty) ...[
                  FloatingActionButton.extended(
                    heroTag: 'tracking-call-${widget.orderId}',
                    onPressed: () =>
                        unawaited(_callRestaurant(restaurantPhone)),
                    icon: const Icon(Icons.phone_outlined),
                    label: const Text('تواصل'),
                  ),
                  const SizedBox(width: 10),
                ],
                FloatingActionButton.extended(
                  heroTag: 'tracking-chat-${widget.orderId}',
                  onPressed: _openChatPage,
                  icon: const Icon(Icons.chat_bubble_outline),
                  label: const Text('محادثة'),
                ),
              ],
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

class _TrackingLiveRouteCard extends StatefulWidget {
  const _TrackingLiveRouteCard({
    required this.order,
  });

  final Map<String, dynamic> order;

  @override
  State<_TrackingLiveRouteCard> createState() => _TrackingLiveRouteCardState();
}

class _TrackingLiveRouteCardState extends State<_TrackingLiveRouteCard> {
  Timer? _clockRefreshTimer;
  _TrackingRouteSnapshot? _snapshot;
  bool _arrivalLocked = false;

  @override
  void initState() {
    super.initState();
    _syncSnapshot();
    _clockRefreshTimer = Timer.periodic(
      const Duration(seconds: 20),
      (_) {
        if (mounted) {
          setState(() {});
        }
      },
    );
  }

  @override
  void didUpdateWidget(covariant _TrackingLiveRouteCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!mapEquals(oldWidget.order, widget.order)) {
      _syncSnapshot();
      setState(() {});
    }
  }

  @override
  void dispose() {
    _clockRefreshTimer?.cancel();
    super.dispose();
  }

  void _syncSnapshot() {
    _snapshot = _TrackingRouteSnapshot.fromOrder(widget.order);
    final normalizedStatus =
        normalizeOrderStatus(widget.order['status']?.toString());
    if (normalizedStatus != 'delivered') {
      _arrivalLocked = false;
      return;
    }
    if (_snapshot?.isDriverArrived == true) {
      _arrivalLocked = true;
    }
  }

  String? _progressBannerText(double progress) {
    if (progress >= 1) {
      return '📍 وصل السائق إلى موقعك.';
    }
    if (progress >= 0.5) {
      return '🚗 السائق أصبح قريبًا منك.';
    }
    return null;
  }

  String _progressLabel(double progress) {
    return '${(progress * 100).round()}%';
  }

  String _etaLabel(double? remainingDistanceMeters) {
    if (remainingDistanceMeters == 0) {
      return 'وصل السائق';
    }
    if (remainingDistanceMeters == null) {
      return 'جارٍ احتساب وقت الوصول.';
    }

    const averageMetersPerMinute = 320.0;
    final minutes =
        math.max(1, (remainingDistanceMeters / averageMetersPerMinute).round());
    if (minutes >= 60) {
      final hours = minutes ~/ 60;
      final remainingMinutes = minutes % 60;
      if (remainingMinutes == 0) {
        return 'حوالي $hours ساعة';
      }
      return 'حوالي $hours ساعة و$remainingMinutes دقيقة';
    }
    return 'حوالي $minutes دقيقة';
  }

  String _lastUpdatedLabel() {
    final updatedAt = DateTime.tryParse(
          widget.order['driver_presence_updated_at']?.toString() ??
              widget.order['updated_at']?.toString() ??
              '',
        ) ??
        OrdersService.createdAtOf(widget.order);
    final elapsed = DateTime.now().difference(updatedAt.toLocal());
    if (elapsed.inSeconds < 60) {
      return 'آخر تحديث الآن';
    }
    if (elapsed.inMinutes < 60) {
      return 'آخر تحديث منذ ${elapsed.inMinutes} دقيقة';
    }
    return 'آخر تحديث ${formatOrderDate(updatedAt)}';
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    if (snapshot == null) {
      return const SizedBox.shrink();
    }

    final normalizedStatus =
        normalizeOrderStatus(widget.order['status']?.toString());
    final progress = _arrivalLocked
        ? 1.0
        : (snapshot.driverProgressFraction ?? 0.0).clamp(0.0, 1.0).toDouble();
    final remainingDistanceMeters = _arrivalLocked
        ? 0.0
        : snapshot.remainingDriverDistanceToCustomer ??
            snapshot.routeDistanceMeters ??
            snapshot.totalDistanceToCustomer;
    final totalDistance =
        snapshot.routeDistanceMeters ?? snapshot.totalDistanceToCustomer;
    final driverGpsAvailable = snapshot.driverPoint != null;
    final bannerText =
        normalizedStatus == 'delivered' ? _progressBannerText(progress) : null;
    final bannerIsArrival = progress >= 1;

    return OrderSectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'التتبع الحي',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 10),
          if (bannerText != null) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: bannerIsArrival
                    ? const Color(0xFFE8F5E9)
                    : const Color(0xFFFFF3E0),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: bannerIsArrival
                      ? const Color(0xFFA5D6A7)
                      : const Color(0xFFFFD8A8),
                ),
              ),
              child: Text(
                bannerText,
                textAlign: TextAlign.right,
                style: TextStyle(
                  color: bannerIsArrival
                      ? const Color(0xFF1F8A5B)
                      : const Color(0xFF9A3412),
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
          Row(
            children: [
              Expanded(
                child: _TrackingMetricPill(
                  icon: Icons.percent_rounded,
                  label: 'نسبة التقدم',
                  value: _progressLabel(progress),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _TrackingMetricPill(
                  icon: Icons.route_rounded,
                  label: 'المسافة المتبقية',
                  value: remainingDistanceMeters == null
                      ? 'جارٍ التحديث'
                      : _TrackingDeliveryProgress.distanceLabel(
                          remainingDistanceMeters,
                        ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _TrackingMetricPill(
                  icon: Icons.schedule_rounded,
                  label: 'وقت الوصول',
                  value: _etaLabel(remainingDistanceMeters),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _TrackingMetricPill(
                  icon: Icons.sync_rounded,
                  label: 'تحديث المسار',
                  value: _lastUpdatedLabel(),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          _TrackingDriverRouteBar(progress: progress),
          const SizedBox(height: 12),
          Text(
            totalDistance == null
                ? 'جارٍ تجهيز مسار الرحلة المباشر.'
                : driverGpsAvailable
                    ? 'المسافة الكلية للرحلة ${_TrackingDeliveryProgress.distanceLabel(totalDistance)} ويتم تحديث حركة السائق مباشرة حسب GPS الحقيقي.'
                    : 'المسافة الكلية للرحلة ${_TrackingDeliveryProgress.distanceLabel(totalDistance)} وبانتظار أول تحديث مباشر من GPS السائق.',
            style: const TextStyle(
              color: Color(0xFF667085),
              fontWeight: FontWeight.w700,
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }
}

class _TrackingMetricPill extends StatelessWidget {
  const _TrackingMetricPill({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFD9E2EC)),
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: AppTheme.primary.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, size: 18, color: AppTheme.primary),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    color: Color(0xFF667085),
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF101828),
                    fontWeight: FontWeight.w800,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TrackingDrawer extends StatelessWidget {
  const _TrackingDrawer({
    required this.order,
    this.onOpenChat,
  });

  final Map<String, dynamic>? order;
  final VoidCallback? onOpenChat;

  @override
  Widget build(BuildContext context) {
    final statusText = order == null
        ? null
        : resolveOrderStatus(order!['status']?.toString()).text;
    final receipt =
        order == null ? null : OrdersService.receiptNumberOf(order!);

    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [AppTheme.primary, AppTheme.secondary],
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'قائمة التتبع',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  if (receipt != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      'ريسيت #$receipt',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                  if (statusText != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      statusText,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 8),
                children: [
                  ListTile(
                    leading: const Icon(Icons.home_outlined),
                    title: const Text('الرئيسية'),
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.of(context).popUntil((route) => route.isFirst);
                    },
                  ),
                  if (onOpenChat != null)
                    ListTile(
                      leading: const Icon(Icons.chat_bubble_outline_rounded),
                      title: const Text('محادثة الطلب'),
                      onTap: () {
                        Navigator.pop(context);
                        onOpenChat!.call();
                      },
                    ),
                  ListTile(
                    leading: const Icon(Icons.close_rounded),
                    title: const Text('إغلاق القائمة'),
                    onTap: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TrackingOrderSummaryCard extends StatelessWidget {
  const _TrackingOrderSummaryCard({
    required this.order,
  });

  final Map<String, dynamic> order;

  @override
  Widget build(BuildContext context) {
    final statusInfo = resolveOrderStatus(order['status']?.toString());
    final orderId = OrdersService.idOf(order);
    final orderNumber =
        orderId.isEmpty ? '--' : '#${OrdersService.shortIdOf(order)}';

    return OrderSectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'تفاصيل الطلب',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 14),
          _TrackingMetaRow(
            icon: Icons.receipt_long_outlined,
            label: 'رقم الطلب',
            value: orderNumber,
          ),
          const SizedBox(height: 10),
          _TrackingMetaRow(
            icon: Icons.confirmation_number_outlined,
            label: 'رقم الريسيت',
            value: OrdersService.receiptNumberOf(order),
          ),
          const SizedBox(height: 10),
          _TrackingMetaRow(
            icon: Icons.flag_outlined,
            label: 'حالة الطلب الحالية',
            value: statusInfo.text,
          ),
          const SizedBox(height: 10),
          _TrackingMetaRow(
            icon: Icons.person_outline_rounded,
            label: 'اسم العميل',
            value: OrdersService.customerNameOf(order),
          ),
          const SizedBox(height: 10),
          _TrackingMetaRow(
            icon: Icons.payments_outlined,
            label: 'الإجمالي النهائي',
            value: formatPrice(OrdersService.totalPriceOf(order)),
          ),
          const SizedBox(height: 10),
          _TrackingMetaRow(
            icon: Icons.calendar_today_outlined,
            label: 'تاريخ ووقت الطلب',
            value: formatOrderDate(OrdersService.createdAtOf(order)),
          ),
        ],
      ),
    );
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
    final restaurantPhone = OrdersService.restaurantPhoneOf(order);

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
            label: 'اسم المطعم',
            value: OrdersService.restaurantNameOf(order),
          ),
          const SizedBox(height: 10),
          _TrackingMetaRow(
            icon: Icons.location_on_outlined,
            label: 'عنوان المطعم',
            value: OrdersService.restaurantAddressOf(order),
            maxValueLines: 4,
          ),
          if (restaurantPhone != null && restaurantPhone.isNotEmpty) ...[
            const SizedBox(height: 14),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: OutlinedButton.icon(
                onPressed: () => onCall(restaurantPhone),
                icon: const Icon(Icons.phone_outlined),
                label: Text(restaurantPhone),
              ),
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
    final customerPhone = OrdersService.customerPhoneOf(order);

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
          _TrackingMetaRow(
            icon: Icons.location_city_outlined,
            label: 'العنوان الكامل',
            value: OrdersService.addressOf(order),
            maxValueLines: 4,
          ),
          const SizedBox(height: 10),
          _TrackingMetaRow(
            icon: Icons.phone_android_outlined,
            label: 'رقم العميل',
            value: customerPhone == null || customerPhone.isEmpty
                ? 'غير متوفر'
                : customerPhone,
          ),
          const SizedBox(height: 10),
          _TrackingMetaRow(
            icon: Icons.notes_rounded,
            label: 'تفاصيل التوصيل',
            value: OrdersService.deliveryDetailsOf(order),
            maxValueLines: 4,
          ),
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
    final itemsAnimationDuration = kIsWeb
        ? const Duration(milliseconds: 140)
        : AppTheme.sectionTransitionDuration;
    var subtotal = 0.0;
    for (final item in items) {
      final qty = OrdersService.quantityOfItem(item).clamp(1, 9999);
      subtotal += OrdersService.itemPriceOf(item) * qty;
    }
    if (subtotal <= 0) {
      final fallbackSubtotal = totalPrice - deliveryCost;
      subtotal = fallbackSubtotal > 0 ? fallbackSubtotal : totalPrice;
    }

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
          AnimatedSwitcher(
            duration: itemsAnimationDuration,
            switchInCurve: AppTheme.emphasizedCurve,
            switchOutCurve: Curves.easeInCubic,
            child: items.isEmpty
                ? const Align(
                    key: ValueKey('tracking-items-empty'),
                    alignment: Alignment.centerRight,
                    child: Text(
                      'لا توجد أصناف مرتبطة بهذا الطلب.',
                      style: TextStyle(color: Color(0xFF667085)),
                    ),
                  )
                : Column(
                    key: ValueKey('tracking-items-${items.length}'),
                    children: items.map((item) {
                      final qty =
                          OrdersService.quantityOfItem(item).clamp(1, 9999);
                      final unitPrice = OrdersService.itemPriceOf(item);
                      final lineTotal = unitPrice * qty;

                      return Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF8FAFC),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: const Color(0xFFD9E2EC),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              OrdersService.itemNameOf(item),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    'الكمية: $qty',
                                    style: const TextStyle(
                                      color: Color(0xFF475467),
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                Expanded(
                                  child: Text(
                                    'السعر: ${formatPrice(unitPrice)}',
                                    textAlign: TextAlign.end,
                                    style: const TextStyle(
                                      color: Color(0xFF475467),
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Align(
                              alignment: AlignmentDirectional.centerEnd,
                              child: Text(
                                'الإجمالي: ${formatPrice(lineTotal)}',
                                style: const TextStyle(
                                  color: AppTheme.primaryDeep,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    }).toList(growable: false),
                  ),
          ),
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
                'إجمالي الأصناف',
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
                'رسوم التوصيل',
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
    this.maxValueLines = 2,
  });

  final IconData icon;
  final String label;
  final String value;
  final int maxValueLines;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: const Color(0xFF667085)),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(
                  color: Color(0xFF667085),
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                value,
                maxLines: maxValueLines,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFF101828),
                  fontWeight: FontWeight.w700,
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

String _trackingStatusLabelForCustomer(String rawStatus) {
  return resolveOrderStatus(rawStatus).text;
}

class _TrackingStatusCard extends StatelessWidget {
  const _TrackingStatusCard({
    required this.order,
  });

  final Map<String, dynamic> order;

  @override
  Widget build(BuildContext context) {
    final animationDuration =
        kIsWeb ? Duration.zero : AppTheme.sectionTransitionDuration;
    final rawStatus = (order['status'] ?? '').toString().trim();
    final mappedRawStatus = _trackingStatusLabelForCustomer(rawStatus);
    final progressState = _TrackingDeliveryProgress.fromOrder(order);

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
              progressState.label,
              key: ValueKey(progressState.label),
              style: TextStyle(
                color: progressState.color,
                fontWeight: FontWeight.w800,
                fontSize: 18,
              ),
            ),
          ),
          if (mappedRawStatus.isNotEmpty &&
              mappedRawStatus != progressState.label)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                mappedRawStatus,
                style: const TextStyle(
                  color: Color(0xFF667085),
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
            ),
          if (progressState.distanceSummary != null) ...[
            const SizedBox(height: 8),
            Text(
              progressState.distanceSummary!,
              style: const TextStyle(
                color: Color(0xFF667085),
                fontWeight: FontWeight.w700,
                fontSize: 12,
              ),
            ),
          ],
          const SizedBox(height: 8),
          Text(
            progressState.driverStatus,
            style: const TextStyle(
              color: Color(0xFF667085),
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
          if (progressState.etaSummary != null) ...[
            const SizedBox(height: 6),
            Text(
              progressState.etaSummary!,
              style: const TextStyle(
                color: Color(0xFF475467),
                fontWeight: FontWeight.w700,
                fontSize: 12,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _TrackingDriverRouteBar extends StatelessWidget {
  const _TrackingDriverRouteBar({
    required this.progress,
  });

  final double progress;

  @override
  Widget build(BuildContext context) {
    final clampedProgress = progress.clamp(0.0, 1.0).toDouble();
    if (kIsWeb) {
      return _TrackingDriverRouteBarFrame(progress: clampedProgress);
    }

    return TweenAnimationBuilder<double>(
      duration: const Duration(milliseconds: 900),
      curve: Curves.easeInOutCubic,
      tween: Tween<double>(end: clampedProgress),
      builder: (context, animatedProgress, _) {
        return _TrackingDriverRouteBarFrame(progress: animatedProgress);
      },
    );
  }
}

class _TrackingDriverRouteBarFrame extends StatelessWidget {
  const _TrackingDriverRouteBarFrame({
    required this.progress,
  });

  final double progress;

  @override
  Widget build(BuildContext context) {
    const endpointWidth = 76.0;
    const endpointBadgeSize = 44.0;
    const driverBadgeSize = 46.0;
    const trackHeight = 10.0;
    final clampedProgress = progress.clamp(0.0, 1.0).toDouble();

    return Directionality(
      textDirection: TextDirection.ltr,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final trackStart = endpointWidth - (endpointBadgeSize / 2);
          final trackEnd =
              constraints.maxWidth - endpointWidth + (endpointBadgeSize / 2);
          final trackWidth = math.max(0.0, trackEnd - trackStart);
          final driverCenter = trackStart + (trackWidth * clampedProgress);
          final driverLeft = (driverCenter - (driverBadgeSize / 2))
              .clamp(0.0, math.max(0.0, constraints.maxWidth - driverBadgeSize))
              .toDouble();

          return Container(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 14),
            decoration: BoxDecoration(
              color: const Color(0xFFFFFCF5),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: const Color(0xFFFFE0B2)),
            ),
            child: SizedBox(
              height: 104,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned(
                    top: 42,
                    left: trackStart,
                    width: trackWidth,
                    child: Container(
                      height: trackHeight,
                      decoration: BoxDecoration(
                        color: const Color(0xFFE5E7EB),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: FractionallySizedBox(
                          widthFactor: clampedProgress,
                          child: Container(
                            decoration: BoxDecoration(
                              color: const Color(0xFFFB8C00),
                              borderRadius: BorderRadius.circular(999),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const Positioned(
                    top: 0,
                    left: 0,
                    child: _TrackingRouteEndpoint(
                      emoji: '🏪',
                      label: 'المطعم',
                      color: Color(0xFF7C4D2A),
                      background: Color(0xFFFFF4E5),
                    ),
                  ),
                  const Positioned(
                    top: 0,
                    right: 0,
                    child: _TrackingRouteEndpoint(
                      emoji: '🏠',
                      label: 'العميل',
                      color: Color(0xFF1565C0),
                      background: Color(0xFFE3F2FD),
                    ),
                  ),
                  Positioned(
                    top: 18,
                    left: driverLeft,
                    child: Container(
                      width: driverBadgeSize,
                      height: driverBadgeSize,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: const Color(0xFFFFE0B2),
                          width: 2,
                        ),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x26000000),
                            blurRadius: 14,
                            offset: Offset(0, 6),
                          ),
                        ],
                      ),
                      alignment: Alignment.center,
                      child: const Text(
                        '🛵',
                        style: TextStyle(fontSize: 21),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _TrackingRouteEndpoint extends StatelessWidget {
  const _TrackingRouteEndpoint({
    required this.emoji,
    required this.label,
    required this.color,
    required this.background,
  });

  final String emoji;
  final String label;
  final Color color;
  final Color background;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 64,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: background,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2),
            ),
            alignment: Alignment.center,
            child: Text(
              emoji,
              style: const TextStyle(fontSize: 20),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w800,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

enum _TrackingDeliveryStage {
  preparing,
  onTheWay,
  nearCustomer,
  delivered,
}

class _TrackingDeliveryProgress {
  const _TrackingDeliveryProgress({
    required this.color,
    required this.label,
    required this.driverStatus,
    this.distanceSummary,
    this.etaSummary,
  });

  final Color color;
  final String label;
  final String driverStatus;
  final String? distanceSummary;
  final String? etaSummary;

  static _TrackingDeliveryProgress fromOrder(Map<String, dynamic> order) {
    final normalizedStatus = normalizeOrderStatus(order['status']?.toString());
    final snapshot = _TrackingRouteSnapshot.fromOrder(order);
    final isFinalDelivered = _isFinalDeliveryStatus(normalizedStatus);
    final isAwaitingCustomerConfirmation =
        normalizedStatus == awaitingCustomerConfirmationStatus;
    final isTransit = _isTransitStatus(normalizedStatus);
    final hasAssignedDriver = OrdersService.driverIdOf(order) != null;
    final hasLiveDriverPoint = snapshot?.driverPoint != null;

    final totalDistance = snapshot?.totalDistanceToCustomer;
    final remainingDistance = snapshot?.remainingDriverDistanceToCustomer;

    if (isFinalDelivered) {
      final summary = totalDistance == null
          ? null
          : 'اكتملت الرحلة (${distanceLabel(totalDistance)})';
      return _TrackingDeliveryProgress(
        color: const Color(0xFF2E7D32),
        label: 'اكتمل الطلب',
        driverStatus: 'حالة السائق: تم إنهاء الطلب بنجاح.',
        distanceSummary: summary,
        etaSummary: 'وقت الوصول المتوقع: اكتمل الطلب.',
      );
    }

    if (isAwaitingCustomerConfirmation) {
      final summary = totalDistance == null
          ? null
          : 'وصل الطلب إلى نقطة التسليم (${distanceLabel(totalDistance)})';
      return _TrackingDeliveryProgress(
        color: const Color(0xFF7C3AED),
        label: 'تم التسليم - بانتظار تأكيد الاستلام',
        driverStatus: 'حالة السائق: أكد تسليم الطلب وينتظر تأكيدك.',
        distanceSummary: summary,
        etaSummary: 'وقت الوصول المتوقع: بانتظار تأكيد الاستلام.',
      );
    }

    final nearThreshold =
        totalDistance == null ? 180.0 : math.max(130.0, totalDistance * 0.12);

    final bool nearCustomer = isTransit &&
        hasLiveDriverPoint &&
        remainingDistance != null &&
        remainingDistance <= nearThreshold;

    final _TrackingDeliveryStage stage;
    if (nearCustomer) {
      stage = _TrackingDeliveryStage.nearCustomer;
    } else if (isTransit) {
      stage = _TrackingDeliveryStage.onTheWay;
    } else {
      stage = _TrackingDeliveryStage.preparing;
    }

    final summary = totalDistance == null
        ? null
        : remainingDistance == null
            ? 'المسافة الكلية ${distanceLabel(totalDistance)}'
            : 'المتبقي ${distanceLabel(remainingDistance)} من ${distanceLabel(totalDistance)}';

    return _TrackingDeliveryProgress(
      color: switch (stage) {
        _TrackingDeliveryStage.preparing => const Color(0xFFF4B400),
        _TrackingDeliveryStage.onTheWay => const Color(0xFFFB8C00),
        _TrackingDeliveryStage.nearCustomer => const Color(0xFF1F8A5B),
        _TrackingDeliveryStage.delivered => const Color(0xFF2E7D32),
      },
      label: switch (stage) {
        _TrackingDeliveryStage.preparing => 'قيد التحضير',
        _TrackingDeliveryStage.onTheWay => 'في الطريق',
        _TrackingDeliveryStage.nearCustomer => 'قريب من العميل',
        _TrackingDeliveryStage.delivered => 'تم التسليم',
      },
      driverStatus: _driverStatusLabel(
        stage: stage,
        hasAssignedDriver: hasAssignedDriver,
        hasLiveDriverPoint: hasLiveDriverPoint,
      ),
      distanceSummary: summary,
      etaSummary: _etaSummaryLabel(
        stage: stage,
        remainingDistance: remainingDistance,
        hasAssignedDriver: hasAssignedDriver,
      ),
    );
  }

  static String _etaSummaryLabel({
    required _TrackingDeliveryStage stage,
    required double? remainingDistance,
    required bool hasAssignedDriver,
  }) {
    if (stage == _TrackingDeliveryStage.delivered) {
      return 'وقت الوصول المتوقع: تم التسليم.';
    }
    if (!hasAssignedDriver) {
      return 'وقت الوصول المتوقع: جارِ تعيين السائق.';
    }
    if (remainingDistance == null) {
      return 'وقت الوصول المتوقع: جارِ احتساب الوقت.';
    }

    const averageMetersPerMinute = 320.0;
    var minutes = (remainingDistance / averageMetersPerMinute).round();
    switch (stage) {
      case _TrackingDeliveryStage.preparing:
        minutes += 10;
        break;
      case _TrackingDeliveryStage.onTheWay:
        minutes += 3;
        break;
      case _TrackingDeliveryStage.nearCustomer:
        minutes = minutes.clamp(1, 8);
        break;
      case _TrackingDeliveryStage.delivered:
        minutes = 0;
        break;
    }

    if (minutes < 1) {
      minutes = 1;
    }
    return 'وقت الوصول المتوقع: حوالي ${_minutesLabel(minutes)}';
  }

  static String _minutesLabel(int minutes) {
    if (minutes >= 60) {
      final hours = minutes ~/ 60;
      final remainingMinutes = minutes % 60;
      if (remainingMinutes == 0) {
        return '$hours ساعة';
      }
      return '$hours ساعة و$remainingMinutes دقيقة';
    }
    return '$minutes دقيقة';
  }

  static String _driverStatusLabel({
    required _TrackingDeliveryStage stage,
    required bool hasAssignedDriver,
    required bool hasLiveDriverPoint,
  }) {
    if (stage == _TrackingDeliveryStage.delivered) {
      return 'حالة السائق: تم إنهاء التوصيل.';
    }
    if (stage == _TrackingDeliveryStage.nearCustomer) {
      return 'حالة السائق: قريب جدًا من العميل.';
    }
    if (stage == _TrackingDeliveryStage.onTheWay) {
      if (hasLiveDriverPoint) {
        return 'حالة السائق: متجه الآن إلى العميل.';
      }
      if (hasAssignedDriver) {
        return 'حالة السائق: تم التعيين وجارٍ تحديث موقعه.';
      }
      return 'حالة السائق: جارِ تعيين سائق للطلب.';
    }
    if (hasAssignedDriver) {
      return 'حالة السائق: بانتظار الانطلاق من المطعم.';
    }
    return 'حالة السائق: لم يتم تعيين سائق بعد.';
  }

  static bool _isTransitStatus(String normalizedStatus) {
    return normalizedStatus == 'delivered' ||
        normalizedStatus == 'on_way' ||
        normalizedStatus == 'on_the_way' ||
        normalizedStatus == 'on_theway' ||
        normalizedStatus == 'onway' ||
        normalizedStatus == 'arrived';
  }

  static bool _isFinalDeliveryStatus(String normalizedStatus) {
    return normalizedStatus == 'completed' ||
        normalizedStatus == 'done' ||
        normalizedStatus == 'delivered_final' ||
        normalizedStatus == 'delivered_confirmed' ||
        normalizedStatus == 'delivery_confirmed' ||
        normalizedStatus == 'received';
  }

  static String distanceLabel(double meters) {
    if (meters < 1000) {
      return '${meters.round()} م';
    }

    final km = meters / 1000;
    if (km >= 10) {
      return '${km.toStringAsFixed(0)} كم';
    }
    return '${km.toStringAsFixed(1)} كم';
  }
}

class _TrackingRouteSnapshot {
  static const double arrivalSnapDistanceMeters = 35.0;

  const _TrackingRouteSnapshot({
    required this.customerPoint,
    this.restaurantPoint,
    this.driverPoint,
  });

  final _TrackingGeoPoint customerPoint;
  final _TrackingGeoPoint? restaurantPoint;
  final _TrackingGeoPoint? driverPoint;

  static _TrackingRouteSnapshot? fromOrder(Map<String, dynamic> order) {
    final customerLat = OrdersService.customerLatOf(order);
    final customerLng = OrdersService.customerLngOf(order);
    if (customerLat == null || customerLng == null) {
      return null;
    }

    final restaurantLat = OrdersService.restaurantLatOf(order);
    final restaurantLng = OrdersService.restaurantLngOf(order);
    final driverLat = OrdersService.driverLatOf(order);
    final driverLng = OrdersService.driverLngOf(order);

    return _TrackingRouteSnapshot(
      customerPoint: _TrackingGeoPoint(customerLat, customerLng),
      restaurantPoint: restaurantLat != null && restaurantLng != null
          ? _TrackingGeoPoint(restaurantLat, restaurantLng)
          : null,
      driverPoint: driverLat != null && driverLng != null
          ? _TrackingGeoPoint(driverLat, driverLng)
          : null,
    );
  }

  double? get routeDistanceMeters {
    if (restaurantPoint == null) {
      return null;
    }
    return _TrackingGeoPoint.distanceMeters(restaurantPoint!, customerPoint);
  }

  double? get totalDistanceToCustomer {
    final fromPoint = restaurantPoint ?? driverPoint;
    if (fromPoint == null) {
      return null;
    }
    return _TrackingGeoPoint.distanceMeters(fromPoint, customerPoint);
  }

  double? get remainingDriverDistanceToCustomer {
    if (driverPoint == null) {
      return routeDistanceMeters ?? totalDistanceToCustomer;
    }
    return _TrackingGeoPoint.distanceMeters(driverPoint!, customerPoint);
  }

  double? get driverProgressFraction {
    final totalDistance = routeDistanceMeters;
    if (totalDistance == null || totalDistance <= 1) {
      return null;
    }
    if (driverPoint == null) {
      return 0.0;
    }

    final remainingDistance =
        _TrackingGeoPoint.distanceMeters(driverPoint!, customerPoint);
    if (remainingDistance <= arrivalSnapDistanceMeters) {
      return 1.0;
    }
    return ((totalDistance - remainingDistance) / totalDistance)
        .clamp(0.0, 1.0)
        .toDouble();
  }

  bool get isDriverArrived {
    final remainingDistance = remainingDriverDistanceToCustomer;
    return remainingDistance != null &&
        remainingDistance <= arrivalSnapDistanceMeters;
  }
}

class _TrackingGeoPoint {
  const _TrackingGeoPoint(this.latitude, this.longitude);

  final double latitude;
  final double longitude;

  static double distanceMeters(_TrackingGeoPoint start, _TrackingGeoPoint end) {
    const earthRadius = 6371000.0;
    final dLat = (end.latitude - start.latitude) * (math.pi / 180);
    final dLng = (end.longitude - start.longitude) * (math.pi / 180);
    final lat1 = start.latitude * (math.pi / 180);
    final lat2 = end.latitude * (math.pi / 180);

    final haversine = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1) *
            math.cos(lat2) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    final centralAngle =
        2 * math.atan2(math.sqrt(haversine), math.sqrt(1 - haversine));
    return earthRadius * centralAngle;
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
