import 'dart:math';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/services/error_logger.dart';
import '../core/orders/order_status_utils.dart';
import 'restaurants_service.dart';
import 'session_manager.dart';

class OrderLimitExceededException implements Exception {
  const OrderLimitExceededException([
    this.message = 'لا يمكنك إنشاء أكثر من طلبين في نفس الوقت.',
  ]);

  final String message;

  @override
  String toString() => message;
}

class CreateOrderItemInput {
  const CreateOrderItemInput({
    required this.name,
    required this.price,
    required this.quantity,
  });

  final String name;
  final double price;
  final int quantity;

  Map<String, dynamic> toRpcJson() {
    return {
      'item_name': name,
      'price': price,
      'qty': quantity,
    };
  }

  Map<String, dynamic> toOrderItemInsert(String orderId) {
    return {
      'order_id': orderId,
      'item_name': name,
      'price': price,
      'qty': quantity,
    };
  }
}

class CreateOrderInput {
  const CreateOrderInput({
    required this.userId,
    required this.restaurantId,
    required this.customerName,
    required this.customerPhone,
    required this.address,
    required this.customerLat,
    required this.customerLng,
    required this.totalPrice,
    required this.deliveryCost,
    required this.items,
  });

  final String userId;
  final String restaurantId;
  final String customerName;
  final String customerPhone;
  final String address;
  final double customerLat;
  final double customerLng;
  final double totalPrice;
  final double deliveryCost;
  final List<CreateOrderItemInput> items;
}

class OrdersService {
  OrdersService._();

  static final SupabaseClient _client = Supabase.instance.client;
  static const Duration _cacheTtl = Duration(seconds: 30);
  static final Map<String, _OrderCacheEntry<List<Map<String, dynamic>>>>
      _customerOrdersCache = {};
  static final Map<String, _OrderCacheEntry<Map<String, dynamic>>> _orderCache =
      {};
  static final Map<String, _OrderCacheEntry<List<Map<String, dynamic>>>>
      _orderItemsCache = {};

  static const List<String> activeStatuses = [
    'pending',
    'accepted',
    'on_the_way',
  ];

  static const List<String> _orderOwnerColumns = [
    'customer_id',
    'user_id',
  ];
  static const String _orderSelect = '*';
  static Future<List<Map<String, dynamic>>> getCustomerOrders(
    String userId, {
    bool forceRefresh = false,
  }) async {
    try {
      final cacheKey = userId.trim();
      final cached = _readCache(
        _customerOrdersCache,
        cacheKey,
        forceRefresh: forceRefresh,
      );
      if (cached != null) {
        return cached;
      }

      final rows = await _runOrderListQueryWithOwnerFallback(
        userId: userId,
        query: (ownerColumn) =>
            SessionManager.instance.runWithValidSession<List<dynamic>>(
          () => _client
              .from('orders')
              .select(_orderSelect)
              .eq(ownerColumn, userId)
              .order('created_at', ascending: false),
          requireSession: true,
        ),
      );

      final orders = await _hydrateOrders(_mapRows(rows));
      _writeCache(_customerOrdersCache, cacheKey, orders);
      for (final order in orders) {
        _writeOrderCache(order);
      }
      return orders;
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'orders_service.getCustomerOrders',
        error: error,
        stack: stack,
      );
      throw Exception(ErrorLogger.userMessage);
    }
  }

  static Future<Map<String, dynamic>?> getOrderById(
    String orderId, {
    String? userId,
    bool forceRefresh = false,
  }) async {
    try {
      final cacheKey = orderId.trim();
      final cached = _readCache(
        _orderCache,
        cacheKey,
        forceRefresh: forceRefresh,
      );
      if (cached != null) {
        return cached;
      }

      final row = await _fetchOrderRow(
        orderId: orderId,
        userId: userId,
      );

      if (row == null) {
        return null;
      }

      final hydrated = await _hydrateOrder(row);
      _writeOrderCache(hydrated);
      return hydrated;
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'orders_service.getOrderById',
        error: error,
        stack: stack,
      );
      throw Exception(ErrorLogger.userMessage);
    }
  }

  static Future<List<Map<String, dynamic>>> getOrderItems(
    String orderId, {
    bool forceRefresh = false,
  }) async {
    try {
      final cacheKey = orderId.trim();
      final cached = _readCache(
        _orderItemsCache,
        cacheKey,
        forceRefresh: forceRefresh,
      );
      if (cached != null) {
        return cached;
      }

      final rows =
          await SessionManager.instance.runWithValidSession<List<dynamic>>(
        () => _client
            .from('order_items')
            .select('*')
            .eq('order_id', orderId)
            .order('created_at'),
        requireSession: true,
      );

      final items = _mapRows(rows);
      _writeCache(_orderItemsCache, cacheKey, items);
      return items;
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'orders_service.getOrderItems',
        error: error,
        stack: stack,
      );
      throw Exception(ErrorLogger.userMessage);
    }
  }

  static Future<int> getActiveOrdersCount(String userId) async {
    final rows = await _runOrderListQueryWithOwnerFallback(
      userId: userId,
      query: (ownerColumn) =>
          SessionManager.instance.runWithValidSession<List<dynamic>>(
        () => _client
            .from('orders')
            .select('id')
            .eq(ownerColumn, userId)
            .inFilter('status', activeStatuses),
        requireSession: true,
      ),
    );

    return rows?.length ?? 0;
  }

  static Future<String> createOrder(CreateOrderInput input) async {
    try {
      final activeCount = await getActiveOrdersCount(input.userId);
      if (activeCount >= 2) {
        throw const OrderLimitExceededException();
      }

      try {
        final orderId = await _createOrderViaRpc(input);
        _customerOrdersCache.remove(input.userId.trim());
        return orderId;
      } on PostgrestException catch (error) {
        if (_looksLikeMissingRpc(error)) {
          final orderId = await _createOrderDirect(input);
          _customerOrdersCache.remove(input.userId.trim());
          return orderId;
        }
        rethrow;
      }
    } on OrderLimitExceededException {
      rethrow;
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'orders_service.createOrder',
        error: error,
        stack: stack,
      );
      throw Exception(ErrorLogger.userMessage);
    }
  }

  static String idOf(Map<String, dynamic> order) {
    return _stringValue(order['id']) ?? '';
  }

  static String shortIdOf(Map<String, dynamic> order) {
    final id = idOf(order);
    if (id.length <= 8) {
      return id;
    }
    return id.substring(0, 8);
  }

  static String orderIdOfItem(Map<String, dynamic> item) {
    return _stringValue(item['order_id']) ?? '';
  }

  static String itemIdOf(Map<String, dynamic> item) {
    return _stringValue(item['id']) ?? '';
  }

  static String receiptNumberOf(Map<String, dynamic> order) {
    return _stringValue(order['receipt_number']) ?? '--';
  }

  static String normalizedStatusOf(Map<String, dynamic> order) {
    return normalizeOrderStatus(order['status']?.toString());
  }

  static OrderStatusStage statusStageOf(Map<String, dynamic> order) {
    return parseOrderStatus(order['status']?.toString());
  }

  static double totalPriceOf(Map<String, dynamic> order) {
    return toDouble(order['total_price']) ?? toDouble(order['total']) ?? 0;
  }

  static double deliveryCostOf(Map<String, dynamic> order) {
    return toDouble(order['delivery_cost']) ?? 0;
  }

  static double subtotalOf(Map<String, dynamic> order) {
    final total = totalPriceOf(order);
    final delivery = deliveryCostOf(order);
    final subtotal = total - delivery;
    if (subtotal <= 0) {
      return total;
    }
    return subtotal;
  }

  static String addressOf(Map<String, dynamic> order) {
    return _stringValue(order['address']) ??
        _stringValue(order['delivery_address']) ??
        _stringValue(order['full_address']) ??
        'العنوان غير متاح';
  }

  static String composeDeliveryAddress({
    required String address,
    String? houseNumber,
  }) {
    final normalizedAddress = address.trim();
    final normalizedHouseNumber = houseNumber?.trim() ?? '';
    if (normalizedHouseNumber.isEmpty) {
      return normalizedAddress;
    }
    return '$normalizedAddress - رقم البيت: $normalizedHouseNumber';
  }

  static String customerNameOf(Map<String, dynamic> order) {
    return _stringValue(order['customer_name']) ??
        _stringValue(order['name']) ??
        'العميل';
  }

  static String? customerPhoneOf(Map<String, dynamic> order) {
    return _stringValue(order['customer_phone']) ??
        _stringValue(order['phone']);
  }

  static double? customerLatOf(Map<String, dynamic> order) {
    return toDouble(order['customer_lat']) ?? toDouble(order['lat']);
  }

  static double? customerLngOf(Map<String, dynamic> order) {
    return toDouble(order['customer_lng']) ?? toDouble(order['lng']);
  }

  static double? driverLatOf(Map<String, dynamic> order) {
    return toDouble(order['driver_lat']);
  }

  static double? driverLngOf(Map<String, dynamic> order) {
    return toDouble(order['driver_lng']);
  }

  static String restaurantNameOf(Map<String, dynamic> order) {
    final restaurant = restaurantDataOf(order);
    if (restaurant == null) {
      return _stringValue(order['restaurant_name']) ?? 'مطعم';
    }

    return RestaurantsService.restaurantNameOf(restaurant);
  }

  static String? restaurantImageOf(Map<String, dynamic> order) {
    final restaurant = restaurantDataOf(order);
    if (restaurant == null) {
      return null;
    }

    return RestaurantsService.restaurantImageOf(restaurant);
  }

  static String? restaurantPhoneOf(Map<String, dynamic> order) {
    final restaurant = restaurantDataOf(order);
    if (restaurant == null) {
      return null;
    }

    return RestaurantsService.restaurantPhoneOf(restaurant);
  }

  static double? restaurantLatOf(Map<String, dynamic> order) {
    final restaurant = restaurantDataOf(order);
    if (restaurant == null) {
      return toDouble(order['restaurant_lat']);
    }

    return RestaurantsService.restaurantLatOf(restaurant) ??
        toDouble(order['restaurant_lat']);
  }

  static double? restaurantLngOf(Map<String, dynamic> order) {
    final restaurant = restaurantDataOf(order);
    if (restaurant == null) {
      return toDouble(order['restaurant_lng']);
    }

    return RestaurantsService.restaurantLngOf(restaurant) ??
        toDouble(order['restaurant_lng']);
  }

  static Map<String, dynamic>? restaurantDataOf(Map<String, dynamic> order) {
    final hydrated = order['restaurant_data'];
    if (hydrated is Map) {
      return Map<String, dynamic>.from(hydrated);
    }

    final managers = order['managers'];
    if (managers is Map) {
      return Map<String, dynamic>.from(managers);
    }
    if (managers is List && managers.isNotEmpty && managers.first is Map) {
      return Map<String, dynamic>.from(managers.first as Map);
    }

    final restaurant = order['restaurants'];
    if (restaurant is Map) {
      return Map<String, dynamic>.from(restaurant);
    }
    if (restaurant is List &&
        restaurant.isNotEmpty &&
        restaurant.first is Map) {
      return Map<String, dynamic>.from(restaurant.first as Map);
    }
    return null;
  }

  static double? toDouble(dynamic value) {
    if (value is num) {
      return value.toDouble();
    }
    if (value is String) {
      return double.tryParse(value);
    }
    return null;
  }

  static int quantityOfItem(Map<String, dynamic> item) {
    final value = toDouble(item['qty']) ?? 0;
    return value.round();
  }

  static String itemNameOf(Map<String, dynamic> item) {
    return _stringValue(item['item_name']) ??
        _stringValue(item['name']) ??
        'عنصر';
  }

  static double itemPriceOf(Map<String, dynamic> item) {
    return toDouble(item['price']) ?? 0;
  }

  static DateTime createdAtOf(Map<String, dynamic> row) {
    final createdAt = row['created_at']?.toString();
    return DateTime.tryParse(createdAt ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0);
  }

  static String? orderIdFromItemPayload(PostgresChangePayload payload) {
    return _stringValue(
      payload.newRecord['order_id'] ?? payload.oldRecord['order_id'],
    );
  }

  static List<Map<String, dynamic>> _mapRows(List<dynamic>? rows) {
    if (rows == null) {
      return const [];
    }

    return rows
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList(growable: false);
  }

  static Future<List<Map<String, dynamic>>> _hydrateOrders(
    List<Map<String, dynamic>> orders,
  ) async {
    if (orders.isEmpty) {
      return const [];
    }

    final restaurantIds = orders
        .map((order) => _stringValue(order['restaurant_id']) ?? '')
        .where((id) => id.isNotEmpty)
        .toList(growable: false);
    final restaurantMap =
        await RestaurantsService.getOrderRestaurantsByIds(restaurantIds);

    final hydratedOrders = orders
        .map(
          (order) => _attachRestaurantData(
            order,
            restaurantMap[_stringValue(order['restaurant_id']) ?? ''],
          ),
        )
        .toList(growable: false);
    for (final order in hydratedOrders) {
      _writeOrderCache(order);
    }
    return hydratedOrders;
  }

  static Future<Map<String, dynamic>> _hydrateOrder(
    Map<String, dynamic> order,
  ) async {
    final restaurantId = _stringValue(order['restaurant_id']) ?? '';
    if (restaurantId.isEmpty) {
      return order;
    }

    final restaurantMap =
        await RestaurantsService.getOrderRestaurantsByIds([restaurantId]);
    final hydrated = _attachRestaurantData(order, restaurantMap[restaurantId]);
    _writeOrderCache(hydrated);
    return hydrated;
  }

  static Map<String, dynamic> _attachRestaurantData(
    Map<String, dynamic> order,
    Map<String, dynamic>? restaurant,
  ) {
    if (restaurant == null) {
      return Map<String, dynamic>.from(order);
    }

    return {
      ...order,
      'restaurant_data': restaurant,
    };
  }

  static Future<String> _createOrderViaRpc(CreateOrderInput input) async {
    final response = await SessionManager.instance.runWithValidSession<dynamic>(
      () => _client.rpc(
        'create_order_with_items',
        params: {
          'p_restaurant_id': input.restaurantId,
          'p_customer_id': input.userId,
          'p_customer_name': input.customerName,
          'p_customer_phone': input.customerPhone,
          'p_address': input.address,
          'p_customer_lat': input.customerLat,
          'p_customer_lng': input.customerLng,
          'p_items': input.items.map((item) => item.toRpcJson()).toList(),
        },
      ),
      requireSession: true,
    );

    final orderId = response?.toString().trim() ?? '';
    if (orderId.isEmpty) {
      throw const PostgrestException(message: 'تعذر إنشاء الطلب.');
    }

    await _synchronizeCreatedOrder(
      orderId: orderId,
      userId: input.userId,
      totalPrice: input.totalPrice,
      deliveryCost: input.deliveryCost,
    );

    return orderId;
  }

  static Future<String> _createOrderDirect(CreateOrderInput input) async {
    final receiptNumber = _generateReceiptNumber();
    final orderRow = await _insertOrderRowWithFallback(
      _buildDirectOrderInsertPayloads(
        input: input,
        receiptNumber: receiptNumber,
      ),
    );

    final orderId = _stringValue(orderRow?['id']) ?? '';
    if (orderId.isEmpty) {
      throw const PostgrestException(message: 'تعذر إنشاء الطلب.');
    }

    if (input.items.isNotEmpty) {
      await SessionManager.instance.runWithValidSession<void>(
        () async {
          await _client.from('order_items').insert(
                input.items
                    .map((item) => item.toOrderItemInsert(orderId))
                    .toList(growable: false),
              );
        },
        requireSession: true,
      );
    }

    return orderId;
  }

  static Future<void> _synchronizeCreatedOrder({
    required String orderId,
    required String userId,
    required double totalPrice,
    required double deliveryCost,
  }) async {
    try {
      await _updateOrderRowWithFallback(
        orderId: orderId,
        payloads: _buildOrderSynchronizationPayloads(
          userId: userId,
          totalPrice: totalPrice,
          deliveryCost: deliveryCost,
        ),
      );
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'orders_service.synchronizeCreatedOrder',
        error: error,
        stack: stack,
      );
    }
  }

  static bool _looksLikeMissingRpc(PostgrestException error) {
    final message = error.message.toLowerCase();
    return message.contains('create_order_with_items') &&
        (message.contains('could not find') ||
            message.contains('does not exist') ||
            message.contains('function'));
  }

  static Future<List<dynamic>?> _runOrderListQueryWithOwnerFallback({
    required String userId,
    required Future<List<dynamic>?> Function(String ownerColumn) query,
  }) async {
    List<dynamic>? fallbackResult;
    PostgrestException? lastSchemaError;

    for (final ownerColumn in _orderOwnerColumns) {
      try {
        final result = await query(ownerColumn);
        if (result != null && result.isNotEmpty) {
          return result;
        }
        fallbackResult ??= result;
      } on PostgrestException catch (error) {
        if (_isSchemaMismatchError(error)) {
          lastSchemaError = error;
          continue;
        }
        rethrow;
      }
    }

    if (fallbackResult != null) {
      return fallbackResult;
    }
    if (lastSchemaError != null) {
      throw lastSchemaError;
    }
    return const [];
  }

  static Future<Map<String, dynamic>?> _fetchOrderRow({
    required String orderId,
    String? userId,
  }) async {
    final effectiveUserId =
        _stringValue(userId) ?? _client.auth.currentUser?.id;
    if (effectiveUserId == null || effectiveUserId.isEmpty) {
      return SessionManager.instance.runWithValidSession<Map<String, dynamic>?>(
        () async {
          final row = await _client
              .from('orders')
              .select(_orderSelect)
              .eq('id', orderId)
              .maybeSingle();
          return row == null ? null : Map<String, dynamic>.from(row);
        },
        requireSession: true,
      );
    }

    var hadScopedQuery = false;
    for (final ownerColumn in _orderOwnerColumns) {
      try {
        final row = await SessionManager.instance
            .runWithValidSession<Map<String, dynamic>?>(
          () async {
            final data = await _client
                .from('orders')
                .select(_orderSelect)
                .eq('id', orderId)
                .eq(ownerColumn, effectiveUserId)
                .maybeSingle();
            return data == null ? null : Map<String, dynamic>.from(data);
          },
          requireSession: true,
        );
        hadScopedQuery = true;
        if (row != null) {
          return row;
        }
      } on PostgrestException catch (error) {
        if (_isSchemaMismatchError(error)) {
          continue;
        }
        rethrow;
      }
    }

    if (hadScopedQuery) {
      return null;
    }

    return SessionManager.instance.runWithValidSession<Map<String, dynamic>?>(
      () async {
        final row = await _client
            .from('orders')
            .select(_orderSelect)
            .eq('id', orderId)
            .maybeSingle();
        return row == null ? null : Map<String, dynamic>.from(row);
      },
      requireSession: true,
    );
  }

  static List<Map<String, dynamic>> _buildDirectOrderInsertPayloads({
    required CreateOrderInput input,
    required String receiptNumber,
  }) {
    final basePayload = <String, dynamic>{
      'restaurant_id': input.restaurantId,
      'receipt_number': receiptNumber,
      'status': 'pending',
      'delivery_cost': input.deliveryCost,
      'address': input.address,
      'customer_name': input.customerName,
      'customer_phone': input.customerPhone,
    };

    return [
      {
        ...basePayload,
        'customer_id': input.userId,
        'total_price': input.totalPrice,
        'customer_lat': input.customerLat,
        'customer_lng': input.customerLng,
      },
      {
        ...basePayload,
        'customer_id': input.userId,
        'total_price': input.totalPrice,
        'lat': input.customerLat,
        'lng': input.customerLng,
      },
      {
        ...basePayload,
        'customer_id': input.userId,
        'total': input.totalPrice,
        'lat': input.customerLat,
        'lng': input.customerLng,
      },
      {
        ...basePayload,
        'user_id': input.userId,
        'total': input.totalPrice,
        'lat': input.customerLat,
        'lng': input.customerLng,
      },
      {
        ...basePayload,
        'user_id': input.userId,
        'total_price': input.totalPrice,
        'customer_lat': input.customerLat,
        'customer_lng': input.customerLng,
      },
    ];
  }

  static Future<Map<String, dynamic>?> _insertOrderRowWithFallback(
    List<Map<String, dynamic>> payloads,
  ) async {
    PostgrestException? lastSchemaError;

    for (final payload in payloads) {
      try {
        return await SessionManager.instance
            .runWithValidSession<Map<String, dynamic>?>(
          () async {
            final data = await _client
                .from('orders')
                .insert(payload)
                .select('id')
                .single();
            return Map<String, dynamic>.from(data);
          },
          requireSession: true,
        );
      } on PostgrestException catch (error) {
        if (_isSchemaMismatchError(error)) {
          lastSchemaError = error;
          continue;
        }
        rethrow;
      }
    }

    if (lastSchemaError != null) {
      throw lastSchemaError;
    }
    throw const PostgrestException(message: 'تعذر إنشاء الطلب.');
  }

  static List<Map<String, dynamic>> _buildOrderSynchronizationPayloads({
    required String userId,
    required double totalPrice,
    required double deliveryCost,
  }) {
    return [
      {
        'customer_id': userId,
        'total_price': totalPrice,
        'delivery_cost': deliveryCost,
      },
      {
        'customer_id': userId,
        'total': totalPrice,
        'delivery_cost': deliveryCost,
      },
      {
        'user_id': userId,
        'total_price': totalPrice,
        'delivery_cost': deliveryCost,
      },
      {
        'user_id': userId,
        'total': totalPrice,
        'delivery_cost': deliveryCost,
      },
    ];
  }

  static Future<void> _updateOrderRowWithFallback({
    required String orderId,
    required List<Map<String, dynamic>> payloads,
  }) async {
    PostgrestException? lastSchemaError;

    for (final payload in payloads) {
      try {
        await SessionManager.instance.runWithValidSession<void>(
          () async {
            await _client.from('orders').update(payload).eq('id', orderId);
          },
          requireSession: true,
        );
        return;
      } on PostgrestException catch (error) {
        if (_isSchemaMismatchError(error)) {
          lastSchemaError = error;
          continue;
        }
        rethrow;
      }
    }

    if (lastSchemaError != null) {
      throw lastSchemaError;
    }
  }

  static bool _isSchemaMismatchError(PostgrestException error) {
    final message = error.message.toLowerCase();
    return error.code == 'PGRST204' ||
        message.contains('schema cache') ||
        message.contains('could not find') ||
        (message.contains('column') &&
            (message.contains('does not exist') ||
                message.contains('not found') ||
                message.contains('unknown')));
  }

  static String _generateReceiptNumber() {
    final now = DateTime.now();
    final random = Random();
    final stamp = now.millisecondsSinceEpoch.toString();
    final suffix = 100 + random.nextInt(900);
    return 'RC${stamp.substring(stamp.length - 6)}$suffix';
  }

  static String? _stringValue(dynamic value) {
    final text = value?.toString().trim();
    if (text == null || text.isEmpty || text == 'null') {
      return null;
    }
    return text;
  }

  static T? _readCache<T>(
    Map<String, _OrderCacheEntry<T>> cache,
    String key, {
    required bool forceRefresh,
  }) {
    if (forceRefresh) {
      return null;
    }

    final entry = cache[key];
    if (entry == null || entry.isExpired) {
      return null;
    }

    return entry.value;
  }

  static void _writeCache<T>(
    Map<String, _OrderCacheEntry<T>> cache,
    String key,
    T value,
  ) {
    if (key.isEmpty) {
      return;
    }

    cache[key] = _OrderCacheEntry(
      value: value,
      cachedAt: DateTime.now(),
    );
  }

  static void _writeOrderCache(Map<String, dynamic> order) {
    final orderId = idOf(order);
    if (orderId.isEmpty) {
      return;
    }

    _writeCache(_orderCache, orderId, order);
  }
}

class _OrderCacheEntry<T> {
  const _OrderCacheEntry({
    required this.value,
    required this.cachedAt,
  });

  final T value;
  final DateTime cachedAt;

  bool get isExpired =>
      DateTime.now().difference(cachedAt) > OrdersService._cacheTtl;
}
