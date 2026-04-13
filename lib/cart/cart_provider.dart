import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/orders/order_status_utils.dart';
import '../core/services/error_logger.dart';
import '../services/orders_service.dart';

class CartItem {
  CartItem({
    required this.id,
    required this.name,
    required this.price,
    required this.image,
    this.qty = 1,
  });

  final String id;
  final String name;
  final double price;
  final String image;
  int qty;

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'price': price,
      'image': image,
      'qty': qty,
    };
  }

  factory CartItem.fromMap(Map<String, dynamic> map) {
    return CartItem(
      id: (map['id'] ?? '').toString(),
      name: (map['name'] ?? '').toString(),
      price: _toDouble(map['price']),
      image: (map['image'] ?? '').toString(),
      qty: (map['qty'] as num?)?.toInt() ?? 1,
    );
  }

  static double _toDouble(dynamic value) {
    if (value is num) {
      return value.toDouble();
    }
    return double.tryParse(value?.toString() ?? '') ?? 0;
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
  static const String _storageKey = 'customer_cart_state_v2';

  final Map<String, CartItem> _items = {};

  SharedPreferences? _prefs;
  String? _restaurantId;
  String? _deliveryAddress;
  double? _deliveryLat;
  double? _deliveryLng;
  String _houseNumber = '';
  double _deliveryCost = 0;
  String? _activeOrderId;
  bool _restored = false;

  Timer? _persistDebounce;
  bool _persistPending = false;
  bool _disposed = false;

  CartController() {
    unawaited(_restoreState());
  }

  List<CartItem> get items => _items.values.toList(growable: false);
  String? get restaurantId => _restaurantId;
  String? get deliveryAddress => _deliveryAddress;
  double? get deliveryLat => _deliveryLat;
  double? get deliveryLng => _deliveryLng;
  String get houseNumber => _houseNumber;
  double get deliveryCost => _deliveryCost;
  String? get activeOrderId => _activeOrderId;
  bool get hasLocation =>
      _deliveryAddress != null && _deliveryLat != null && _deliveryLng != null;
  bool get isLocked => _activeOrderId != null && _activeOrderId!.isNotEmpty;

  int get totalCount => _items.values.fold(0, (sum, item) => sum + item.qty);
  double get totalPrice => _items.values.fold(
        0,
        (sum, item) => sum + (item.price * item.qty),
      );

  int getQuantity(String id) {
    return _items[id]?.qty ?? 0;
  }

  void addItem({
    required String id,
    required String name,
    required double price,
    required String image,
    String? restaurantId,
  }) {
    if (isLocked) {
      return;
    }

    if (restaurantId != null) {
      if (_restaurantId != null && _restaurantId != restaurantId) {
        _items.clear();
      }
      _restaurantId = restaurantId;
    }

    if (_items.containsKey(id)) {
      _items[id]!.qty++;
    } else {
      _items[id] = CartItem(
        id: id,
        name: name,
        price: price,
        image: image,
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
    _houseNumber = '';
    _deliveryCost = 0;
    _activeOrderId = null;
    _notify();
    _schedulePersist();
  }

  void setDeliveryLocation({
    required String address,
    required double lat,
    required double lng,
    String? houseNumber,
  }) {
    _deliveryAddress = address.trim();
    _deliveryLat = lat;
    _deliveryLng = lng;
    if (houseNumber != null) {
      _houseNumber = houseNumber.trim();
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
    if (_houseNumber == nextValue) {
      return;
    }

    _houseNumber = nextValue;
    // Avoid rebuild storms while typing in the house number field.
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

  Future<void> markOrderPlaced(String orderId) async {
    _activeOrderId = orderId;
    _notify();
    await _persistStateNow();
  }

  Future<void> refreshActiveOrderStatus() async {
    final orderId = _activeOrderId;
    if (orderId == null || orderId.isEmpty) {
      return;
    }

    try {
      final order = await OrdersService.getOrderById(orderId);
      if (order == null) {
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
    final raw = _prefs!.getString(_storageKey);

    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          final itemMaps = (decoded['items'] as List?) ?? const [];
          for (final item in itemMaps) {
            if (item is Map) {
              final parsed = CartItem.fromMap(Map<String, dynamic>.from(item));
              if (parsed.id.isNotEmpty) {
                _items[parsed.id] = parsed;
              }
            }
          }

          _restaurantId = (decoded['restaurant_id'] ?? '').toString().trim();
          if (_restaurantId!.isEmpty) {
            _restaurantId = null;
          }

          final address = (decoded['delivery_address'] ?? '').toString().trim();
          _deliveryAddress = address.isEmpty ? null : address;
          _deliveryLat = _toNullableDouble(decoded['delivery_lat']);
          _deliveryLng = _toNullableDouble(decoded['delivery_lng']);
          _houseNumber = (decoded['house_number'] ?? '').toString().trim();
          _deliveryCost = _toNullableDouble(decoded['delivery_cost']) ?? 0;

          final orderId = (decoded['active_order_id'] ?? '').toString().trim();
          _activeOrderId = orderId.isEmpty ? null : orderId;
        }
      } catch (error, stack) {
        await ErrorLogger.logError(
          module: 'cart_provider.restoreState',
          error: error,
          stack: stack,
        );
        await _prefs!.remove(_storageKey);
      }
    }

    _restored = true;
    _notify();

    if (_persistPending) {
      _schedulePersist();
    }

    await refreshActiveOrderStatus();
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
          _houseNumber.isNotEmpty ||
          _deliveryCost > 0 ||
          _activeOrderId != null;

      if (!hasState) {
        await prefs.remove(_storageKey);
        return;
      }

      await prefs.setString(
        _storageKey,
        jsonEncode({
          'items': _items.values.map((item) => item.toMap()).toList(),
          'restaurant_id': _restaurantId,
          'delivery_address': _deliveryAddress,
          'delivery_lat': _deliveryLat,
          'delivery_lng': _deliveryLng,
          'house_number': _houseNumber,
          'delivery_cost': _deliveryCost,
          'active_order_id': _activeOrderId,
        }),
      );
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'cart_provider.persistState',
        error: error,
        stack: stack,
      );
    }
  }

  static double? _toNullableDouble(dynamic value) {
    if (value is num) {
      return value.toDouble();
    }
    return double.tryParse(value?.toString() ?? '');
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
    super.dispose();
  }
}
