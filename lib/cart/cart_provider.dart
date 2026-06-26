import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/orders/order_status_utils.dart';
import '../core/services/error_logger.dart';
import '../core/stability/offline_order_queue_service.dart';
import '../core/stability/stability_logger.dart';
import '../services/orders_service.dart';

enum CartPaymentMethod {
  cash('cash'),
  visa('visa');

  const CartPaymentMethod(this.value);

  final String value;

  static CartPaymentMethod? fromValue(String? raw) {
    final normalized = raw?.trim().toLowerCase();
    for (final method in CartPaymentMethod.values) {
      if (method.value == normalized) {
        return method;
      }
    }
    return null;
  }
}

class CartItem {
  CartItem({
    required this.id,
    String? itemId,
    required this.name,
    required this.price,
    required this.image,
    this.qty = 1,
    this.variantId = '',
    this.variantName = '',
    double? variantPrice,
    this.modifiers = const <String>[],
    this.note = '',
  })  : itemId = _normalizeItemId(itemId, id),
        variantPrice = variantPrice ?? price;

  final String id;
  final String itemId;
  final String name;
  final double price;
  final String image;
  int qty;
  final String variantId;
  final String variantName;
  final double variantPrice;
  final List<String> modifiers;
  String note;

  String get displayName {
    final normalizedVariantName = variantName.trim();
    if (normalizedVariantName.isEmpty) {
      return name;
    }
    return '$name ($normalizedVariantName)';
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'item_id': itemId,
      'name': name,
      'price': price,
      'image': image,
      'qty': qty,
      'variant_id': variantId,
      'variant_name': variantName,
      'variant_price': variantPrice,
      'modifiers': modifiers,
      'note': note,
    };
  }

  factory CartItem.fromMap(Map<String, dynamic> map) {
    final parsedQty = (map['qty'] as num?)?.toInt() ??
        int.tryParse(map['qty']?.toString() ?? '') ??
        1;
    return CartItem(
      id: (map['id'] ?? '').toString(),
      itemId: (map['item_id'] ?? map['itemId'] ?? '').toString(),
      name: (map['name'] ?? '').toString(),
      price: _toDouble(map['price']),
      image: (map['image'] ?? '').toString(),
      qty: parsedQty < 1 ? 1 : parsedQty,
      variantId: (map['variant_id'] ?? map['variantId'] ?? '').toString(),
      variantName: (map['variant_name'] ?? map['variantName'] ?? '').toString(),
      variantPrice: _toDouble(
        map['variant_price'] ?? map['variantPrice'] ?? map['price'],
      ),
      modifiers: (map['modifiers'] as List? ?? const [])
          .map((item) => item.toString().trim())
          .where((item) => item.isNotEmpty)
          .toList(growable: false),
      note: (map['note'] ?? '').toString(),
    );
  }

  static double _toDouble(dynamic value) {
    if (value is num) {
      return value.toDouble();
    }
    return double.tryParse(value?.toString() ?? '') ?? 0;
  }

  static String _normalizeItemId(String? itemId, String fallbackId) {
    final normalized = itemId?.trim();
    if (normalized != null && normalized.isNotEmpty) {
      return normalized;
    }
    return fallbackId;
  }
}

class CartProvider extends InheritedNotifier<CartController> {
  const CartProvider({
    super.key,
    required CartController controller,
    required super.child,
  }) : super(notifier: controller);

  /// Watch (subscribes) — causes rebuilds on cart changes.
  static CartController of(BuildContext context) {
    final provider = context.dependOnInheritedWidgetOfExactType<CartProvider>();
    final controller = provider?.notifier;
    assert(controller != null, 'CartProvider not found in widget tree.');
    return controller!;
  }

  /// Read (no subscription) — safe to call from callbacks and services.
  static CartController? maybeOf(BuildContext context) {
    return context.getInheritedWidgetOfExactType<CartProvider>()?.notifier;
  }

  /// Read (no subscription).
  static CartController read(BuildContext context) {
    final controller = maybeOf(context);
    assert(controller != null, 'CartProvider not found in widget tree.');
    return controller!;
  }
}

class CartProviderWrapper extends StatefulWidget {
  const CartProviderWrapper({
    super.key,
    required this.child,
  });

  final Widget child;

  @override
  State<CartProviderWrapper> createState() => _CartProviderWrapperState();
}

class _CartProviderWrapperState extends State<CartProviderWrapper> {
  late final CartController _controller = CartController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CartProvider(
      controller: _controller,
      child: widget.child,
    );
  }
}

class CartController extends ChangeNotifier {
  static const String _storageKey = 'customer_cart_state_v3';
  static const String _backupStorageKey = 'customer_cart_state_v3_backup';
  static const int _snapshotVersion = 4;

  final Map<String, CartItem> _items = {};
  final SupabaseClient _supabase = Supabase.instance.client;

  SharedPreferences? _prefs;
  String? _restaurantId;
  String? _deliveryAddress;
  double? _deliveryLat;
  double? _deliveryLng;
  String _buildingNumber = '';
  String _apartmentNumber = '';
  String _floorNumber = '';
  String _landmark = '';
  String _checkoutNotes = '';
  double _deliveryCost = 0;
  String? _activeOrderId;
  CartPaymentMethod? _selectedPaymentMethod;
  String? _appliedCouponCode;
  String? _pendingOrderRequestToken;
  String? _checkoutSessionId;
  bool _restored = false;

  Timer? _persistDebounce;
  bool _persistPending = false;
  bool _disposed = false;
  StreamSubscription<OfflineOrderQueueResult>? _offlineSyncSubscription;

  CartController() {
    _offlineSyncSubscription =
        OfflineOrderQueueService.instance.onSynced.listen(
      (result) {
        unawaited(_handleOfflineOrderSynced(result));
      },
    );
    unawaited(_restoreState());
  }

  List<CartItem> get items => _items.values.toList(growable: false);
  String? get restaurantId => _restaurantId;
  String? get deliveryAddress => _deliveryAddress;
  double? get deliveryLat => _deliveryLat;
  double? get deliveryLng => _deliveryLng;
  String get houseNumber => _buildingNumber;
  String get buildingNumber => _buildingNumber;
  String get apartmentNumber => _apartmentNumber;
  String get floorNumber => _floorNumber;
  String get landmark => _landmark;
  String get checkoutNotes => _checkoutNotes;
  double get deliveryCost => _deliveryCost;
  String? get activeOrderId => _activeOrderId;
  String? get pendingOrderRequestToken => _pendingOrderRequestToken;
  String? get checkoutSessionId => _checkoutSessionId;
  CartPaymentMethod? get selectedPaymentMethod => _selectedPaymentMethod;
  String? get appliedCouponCode => _appliedCouponCode;
  bool get hasLocation =>
      _deliveryAddress != null && _deliveryLat != null && _deliveryLng != null;
  bool get isCheckoutPending =>
      _pendingOrderRequestToken != null &&
      _pendingOrderRequestToken!.isNotEmpty;
  bool get isLocked =>
      (_activeOrderId != null && _activeOrderId!.isNotEmpty) ||
      isCheckoutPending;

  int get totalCount => _items.values.fold(0, (sum, item) => sum + item.qty);
  double get totalPrice => _items.values.fold(
        0,
        (sum, item) => sum + (item.price * item.qty),
      );

  static String lineItemId({
    required String itemId,
    String? variantId,
  }) {
    final normalizedItemId = itemId.trim();
    final normalizedVariantId = variantId?.trim() ?? '';
    if (normalizedVariantId.isEmpty) {
      return normalizedItemId;
    }
    return '$normalizedItemId::variant::$normalizedVariantId';
  }

  int getQuantity(String id, {String? variantId}) {
    return _items[lineItemId(itemId: id, variantId: variantId)]?.qty ?? 0;
  }

  void addItem({
    required String id,
    required String name,
    required double price,
    required String image,
    String? restaurantId,
    String? variantId,
    String? variantName,
    double? variantPrice,
    List<String> modifiers = const <String>[],
    String note = '',
  }) {
    if (isLocked) {
      return;
    }

    final normalizedItemId = id.trim();
    if (normalizedItemId.isEmpty) {
      return;
    }
    final normalizedVariantId = variantId?.trim() ?? '';
    final normalizedVariantName = variantName?.trim() ?? '';
    final effectivePrice = variantPrice ?? price;
    final lineId = lineItemId(
      itemId: normalizedItemId,
      variantId: normalizedVariantId,
    );

    if (restaurantId != null) {
      if (_restaurantId != null && _restaurantId != restaurantId) {
        _items.clear();
      }
      _restaurantId = restaurantId;
    }

    if (_items.containsKey(lineId)) {
      _items[lineId]!.qty++;
    } else {
      _items[lineId] = CartItem(
        id: lineId,
        itemId: normalizedItemId,
        name: name,
        price: effectivePrice,
        image: image,
        variantId: normalizedVariantId,
        variantName: normalizedVariantName,
        variantPrice: effectivePrice,
        modifiers: modifiers,
        note: note,
      );
    }

    _notify();
    _schedulePersist();
  }

  void removeItem(String id) {
    if (isLocked || !_items.containsKey(id)) {
      return;
    }

    if (_items[id]!.qty > 1) {
      _items[id]!.qty--;
    } else {
      _items.remove(id);
    }

    if (_items.isEmpty) {
      _restaurantId = null;
    }

    _notify();
    _schedulePersist();
  }

  void incrementItem(String id) {
    if (isLocked) {
      return;
    }

    final item = _items[id];
    if (item == null) {
      return;
    }

    item.qty++;
    _notify();
    _schedulePersist();
  }

  void decrementItem(String id) {
    if (isLocked) {
      return;
    }

    final item = _items[id];
    if (item == null || item.qty <= 1) {
      return;
    }

    item.qty--;
    _notify();
    _schedulePersist();
  }

  void updateItemNote(String id, String note) {
    if (isLocked) {
      return;
    }

    final item = _items[id];
    if (item == null) {
      return;
    }

    final normalized = note.trim();
    if (item.note == normalized) {
      return;
    }

    item.note = normalized;
    _schedulePersist();
  }

  void deleteItem(String id) {
    if (isLocked) {
      return;
    }

    _items.remove(id);
    if (_items.isEmpty) {
      _restaurantId = null;
    }

    _notify();
    _schedulePersist();
  }

  void clear() {
    _items.clear();
    _restaurantId = null;
    _deliveryAddress = null;
    _deliveryLat = null;
    _deliveryLng = null;
    _buildingNumber = '';
    _apartmentNumber = '';
    _floorNumber = '';
    _landmark = '';
    _checkoutNotes = '';
    _deliveryCost = 0;
    _activeOrderId = null;
    _selectedPaymentMethod = null;
    _appliedCouponCode = null;
    _pendingOrderRequestToken = null;
    _checkoutSessionId = null;
    _notify();
    _schedulePersist();
  }

  void setDeliveryLocation({
    required String address,
    required double lat,
    required double lng,
    String? houseNumber,
    String? buildingNumber,
    String? apartmentNumber,
    String? floorNumber,
    String? landmark,
    String? notes,
  }) {
    _deliveryAddress = address.trim();
    _deliveryLat = lat;
    _deliveryLng = lng;
    final resolvedBuildingNumber = buildingNumber ?? houseNumber;
    if (resolvedBuildingNumber != null) {
      _buildingNumber = resolvedBuildingNumber.trim();
    }
    if (apartmentNumber != null) {
      _apartmentNumber = apartmentNumber.trim();
    }
    if (floorNumber != null) {
      _floorNumber = floorNumber.trim();
    }
    if (landmark != null) {
      _landmark = landmark.trim();
    }
    if (notes != null) {
      _checkoutNotes = notes.trim();
    }
    _notify();
    _schedulePersist();
  }

  void setDeliveryAddress(String value) {
    final normalized = value.trim();
    final nextValue = normalized.isEmpty ? null : normalized;
    if (_deliveryAddress == nextValue) {
      return;
    }

    _deliveryAddress = nextValue;
    // Avoid rebuild storms while typing in the address field.
    _schedulePersist();
  }

  void setHouseNumber(String value) {
    final nextValue = value.trim();
    if (_buildingNumber == nextValue) {
      return;
    }

    _buildingNumber = nextValue;
    // Avoid rebuild storms while typing in the house number field.
    _schedulePersist();
  }

  void setApartmentNumber(String value) {
    final nextValue = value.trim();
    if (_apartmentNumber == nextValue) {
      return;
    }

    _apartmentNumber = nextValue;
    _schedulePersist();
  }

  void setFloorNumber(String value) {
    final nextValue = value.trim();
    if (_floorNumber == nextValue) {
      return;
    }

    _floorNumber = nextValue;
    _schedulePersist();
  }

  void setLandmark(String value) {
    final nextValue = value.trim();
    if (_landmark == nextValue) {
      return;
    }

    _landmark = nextValue;
    _schedulePersist();
  }

  void setCheckoutNotes(String value) {
    final nextValue = value.trim();
    if (_checkoutNotes == nextValue) {
      return;
    }

    _checkoutNotes = nextValue;
    _schedulePersist();
  }

  void updateDeliveryCost(double value) {
    final double nextValue = value.isFinite ? value : 0.0;
    if (_deliveryCost == nextValue) {
      return;
    }

    _deliveryCost = nextValue;
    _notify();
    _schedulePersist();
  }

  void setPaymentMethod(CartPaymentMethod? method) {
    if (_selectedPaymentMethod == method) {
      return;
    }
    _selectedPaymentMethod = method;
    _notify();
    _schedulePersist();
  }

  void setAppliedCouponCode(String? code) {
    final normalized = code?.trim();
    final next = (normalized == null || normalized.isEmpty) ? null : normalized;
    if (_appliedCouponCode == next) {
      return;
    }
    _appliedCouponCode = next;
    _schedulePersist();
  }

  Future<void> markOrderQueued({
    required String orderRequestToken,
    required String checkoutSessionId,
  }) async {
    _pendingOrderRequestToken = orderRequestToken.trim();
    _checkoutSessionId = checkoutSessionId.trim();
    _notify();
    await _persistStateNow();
    StabilityLogger.cart(
      'Cart locked with offline pending token=$_pendingOrderRequestToken',
    );
  }

  Future<void> markOrderPlaced(String orderId) async {
    _activeOrderId = orderId;
    _pendingOrderRequestToken = null;
    _checkoutSessionId = null;
    _notify();
    await _persistStateNow();
  }

  Future<void> adoptActiveOrder(String orderId) async {
    final normalizedOrderId = orderId.trim();
    if (normalizedOrderId.isEmpty) {
      return;
    }

    if (_activeOrderId == normalizedOrderId &&
        _pendingOrderRequestToken == null &&
        _checkoutSessionId == null) {
      return;
    }

    _activeOrderId = normalizedOrderId;
    _pendingOrderRequestToken = null;
    _checkoutSessionId = null;
    _notify();
    await _persistStateNow();
  }

  Future<void> clearPendingCheckout() async {
    if (!isCheckoutPending) {
      return;
    }
    _pendingOrderRequestToken = null;
    _checkoutSessionId = null;
    _notify();
    await _persistStateNow();
  }

  Future<void> refreshActiveOrderStatus() async {
    if (_activeOrderId == null || _activeOrderId!.isEmpty) {
      await _resolvePendingOrderFromToken();
    }

    var orderId = _activeOrderId;
    if (orderId == null || orderId.isEmpty) {
      await _resolveLatestActiveOrderFromServer();
      orderId = _activeOrderId;
    }

    if (orderId == null || orderId.isEmpty) {
      return;
    }

    try {
      final order = await OrdersService.getOrderById(orderId);
      if (order == null) {
        await _resolveLatestActiveOrderFromServer();
        return;
      }

      syncOrderStatusFromRow(order);
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'cart_provider.refreshActiveOrderStatus',
        error: error,
        stack: stack,
      );
    }
  }

  Future<void> _resolveLatestActiveOrderFromServer() async {
    final userId = _supabase.auth.currentUser?.id;
    if (userId == null || userId.isEmpty) {
      return;
    }

    try {
      final order = await OrdersService.getLatestActiveOrder(
        userId,
        forceRefresh: true,
      );
      if (order == null) {
        return;
      }

      final orderId = OrdersService.idOf(order);
      if (orderId.isEmpty) {
        return;
      }

      _activeOrderId = orderId;
      syncOrderStatusFromRow(order);
      if (_activeOrderId == orderId) {
        _notify();
        _schedulePersist();
      }
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'cart_provider.resolveLatestActiveOrderFromServer',
        error: error,
        stack: stack,
      );
    }
  }

  void syncOrderStatusFromRow(Map<String, dynamic> order) {
    final orderId = OrdersService.idOf(order);
    if (_activeOrderId == null || orderId != _activeOrderId) {
      return;
    }

    final stage = OrdersService.statusStageOf(order);
    if (stage == OrderStatusStage.completed ||
        stage == OrderStatusStage.cancelled) {
      clear();
      return;
    }

    final nextDeliveryCost = OrdersService.deliveryCostOf(order);
    if (_deliveryCost == nextDeliveryCost) {
      return;
    }

    _deliveryCost = nextDeliveryCost;
    _notify();
    _schedulePersist();
  }

  void _schedulePersist() {
    if (!_restored) {
      _persistPending = true;
      return;
    }

    _persistPending = false;
    _persistDebounce?.cancel();
    _persistDebounce = Timer(const Duration(milliseconds: 250), () {
      unawaited(_persistState());
    });
  }

  Future<void> _persistStateNow() async {
    _persistDebounce?.cancel();
    await _persistState();
  }

  Future<void> _restoreState() async {
    _prefs = await SharedPreferences.getInstance();
    final restoredPrimary = await _restoreFromSnapshotKey(_storageKey);
    if (!restoredPrimary) {
      final restoredBackup = await _restoreFromSnapshotKey(_backupStorageKey);
      if (!restoredBackup) {
        await _prefs!.remove(_storageKey);
        await _prefs!.remove(_backupStorageKey);
      }
    }

    _restored = true;
    _notify();

    if (_persistPending) {
      _schedulePersist();
    }

    await refreshActiveOrderStatus();
  }

  Future<bool> _restoreFromSnapshotKey(String key) async {
    final raw = _prefs!.getString(key);
    if (raw == null || raw.isEmpty) {
      return false;
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return false;
      }
      if (!_isSnapshotValid(decoded)) {
        StabilityLogger.cart('Invalid or corrupted cart snapshot at key=$key');
        return false;
      }
      _restoreFromSnapshot(decoded);
      return true;
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'cart_provider.restoreState',
        error: error,
        stack: stack,
      );
      return false;
    }
  }

  bool _isSnapshotValid(Map<String, dynamic> snapshot) {
    final version = (snapshot['version'] as num?)?.toInt() ?? 1;
    if (version > _snapshotVersion) {
      return false;
    }
    final items = snapshot['items'];
    if (items != null && items is! List) {
      return false;
    }
    final restaurantId = snapshot['restaurant_id'];
    if (restaurantId != null && restaurantId is! String) {
      return false;
    }
    return true;
  }

  void _restoreFromSnapshot(Map<String, dynamic> snapshot) {
    _items.clear();
    final itemMaps = (snapshot['items'] as List?) ?? const [];
    for (final item in itemMaps) {
      if (item is! Map) {
        continue;
      }
      final parsed = CartItem.fromMap(Map<String, dynamic>.from(item));
      if (parsed.id.isEmpty) {
        continue;
      }
      _items[parsed.id] = parsed;
    }

    _restaurantId = (snapshot['restaurant_id'] ?? '').toString().trim();
    if (_restaurantId!.isEmpty) {
      _restaurantId = null;
    }

    final address = (snapshot['delivery_address'] ?? '').toString().trim();
    _deliveryAddress = address.isEmpty ? null : address;
    _deliveryLat = _toNullableDouble(snapshot['delivery_lat']);
    _deliveryLng = _toNullableDouble(snapshot['delivery_lng']);
    _buildingNumber = _firstText(snapshot, const [
      'building_number',
      'house_number',
    ]);
    _apartmentNumber = _firstText(snapshot, const [
      'apartment_number',
      'apartment',
    ]);
    _floorNumber = _firstText(snapshot, const [
      'floor_number',
      'floor',
    ]);
    _landmark = _firstText(snapshot, const ['landmark']);
    _checkoutNotes = _firstText(snapshot, const [
      'checkout_notes',
      'notes',
    ]);
    _deliveryCost = _toNullableDouble(snapshot['delivery_cost']) ?? 0;
    _selectedPaymentMethod = CartPaymentMethod.fromValue(
      snapshot['payment_method']?.toString(),
    );
    _appliedCouponCode =
        _normalizeNullableText(snapshot['applied_coupon_code']);

    final orderId = (snapshot['active_order_id'] ?? '').toString().trim();
    _activeOrderId = orderId.isEmpty ? null : orderId;
    _pendingOrderRequestToken =
        _normalizeNullableText(snapshot['pending_order_request_token']);
    _checkoutSessionId =
        _normalizeNullableText(snapshot['checkout_session_id']);
  }

  Future<void> _persistState() async {
    if (!_restored || _disposed) {
      return;
    }

    try {
      final prefs = _prefs ?? await SharedPreferences.getInstance();
      final hasState = _items.isNotEmpty ||
          _restaurantId != null ||
          _deliveryAddress != null ||
          _buildingNumber.isNotEmpty ||
          _apartmentNumber.isNotEmpty ||
          _floorNumber.isNotEmpty ||
          _landmark.isNotEmpty ||
          _checkoutNotes.isNotEmpty ||
          _deliveryCost > 0 ||
          _activeOrderId != null ||
          _selectedPaymentMethod != null ||
          _appliedCouponCode != null ||
          _pendingOrderRequestToken != null ||
          _checkoutSessionId != null;

      if (!hasState) {
        await prefs.remove(_storageKey);
        await prefs.remove(_backupStorageKey);
        return;
      }

      final payload = {
        'version': _snapshotVersion,
        'items': _items.values.map((item) => item.toMap()).toList(),
        'restaurant_id': _restaurantId,
        'delivery_address': _deliveryAddress,
        'delivery_lat': _deliveryLat,
        'delivery_lng': _deliveryLng,
        'house_number': _buildingNumber,
        'building_number': _buildingNumber,
        'apartment_number': _apartmentNumber,
        'floor_number': _floorNumber,
        'landmark': _landmark,
        'checkout_notes': _checkoutNotes,
        'delivery_cost': _deliveryCost,
        'active_order_id': _activeOrderId,
        'payment_method': _selectedPaymentMethod?.value,
        'applied_coupon_code': _appliedCouponCode,
        'pending_order_request_token': _pendingOrderRequestToken,
        'checkout_session_id': _checkoutSessionId,
      };
      final encoded = jsonEncode(payload);
      await prefs.setString(
        _storageKey,
        encoded,
      );
      await prefs.setString(_backupStorageKey, encoded);
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'cart_provider.persistState',
        error: error,
        stack: stack,
      );
    }
  }

  Future<void> _resolvePendingOrderFromToken() async {
    final token = _pendingOrderRequestToken?.trim();
    if (token == null || token.isEmpty) {
      return;
    }
    final userId = _supabase.auth.currentUser?.id;
    if (userId == null || userId.isEmpty) {
      return;
    }

    try {
      final row = await _supabase
          .from('order_request_tokens')
          .select('status, order_id')
          .eq('user_id', userId)
          .eq('order_request_token', token)
          .limit(1)
          .maybeSingle();
      if (row is! Map<String, dynamic>) {
        return;
      }
      final status = row['status']?.toString().trim().toLowerCase();
      final orderId = row['order_id']?.toString().trim();
      if (status == 'completed' && orderId != null && orderId.isNotEmpty) {
        _activeOrderId = orderId;
        _pendingOrderRequestToken = null;
        _checkoutSessionId = null;
        _notify();
        await _persistStateNow();
      }
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'cart_provider.resolvePendingOrderFromToken',
        error: error,
        stack: stack,
      );
    }
  }

  Future<void> _handleOfflineOrderSynced(OfflineOrderQueueResult result) async {
    final pendingToken = _pendingOrderRequestToken?.trim();
    if (pendingToken == null || pendingToken.isEmpty) {
      return;
    }
    if (pendingToken != result.orderRequestToken) {
      return;
    }
    _activeOrderId = result.orderId;
    _pendingOrderRequestToken = null;
    _checkoutSessionId = null;
    _notify();
    await _persistStateNow();
    StabilityLogger.cart(
      'Pending queued order synced token=${result.orderRequestToken} orderId=${result.orderId}',
    );
  }

  static double? _toNullableDouble(dynamic value) {
    if (value is num) {
      return value.toDouble();
    }
    return double.tryParse(value?.toString() ?? '');
  }

  static String? _normalizeNullableText(dynamic value) {
    final text = value?.toString().trim();
    if (text == null || text.isEmpty) {
      return null;
    }
    return text;
  }

  static String _firstText(Map<String, dynamic> source, List<String> keys) {
    for (final key in keys) {
      final text = source[key]?.toString().trim();
      if (text != null && text.isNotEmpty && text != 'null') {
        return text;
      }
    }
    return '';
  }

  void _notify() {
    if (_disposed) {
      return;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _persistDebounce?.cancel();
    unawaited(_offlineSyncSubscription?.cancel());
    super.dispose();
  }
}
