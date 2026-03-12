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

  static const List<String> activeStatuses = [
    'pending',
    'accepted',
    'on_the_way',
  ];

  static const String _orderSelect = '''
id,
restaurant_id,
customer_id,
driver_id,
status,
total,
delivery_cost,
address,
customer_name,
customer_phone,
lat,
lng,
receipt_number,
items_total,
created_at,
house_number
''';
  static Future<List<Map<String, dynamic>>> getCustomerOrders(
    String userId,
  ) async {
    try {
      final rows =
          await SessionManager.instance.runWithValidSession<List<dynamic>>(
        () => _client
            .from('orders')
            .select(_orderSelect)
            .eq('customer_id', userId)
            .order('created_at', ascending: false),
        requireSession: true,
      );

      return _hydrateOrders(_mapRows(rows));
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
  }) async {
    try {
      final row = await SessionManager.instance
          .runWithValidSession<Map<String, dynamic>?>(
        () async {
          var query =
              _client.from('orders').select(_orderSelect).eq('id', orderId);
          if (userId != null && userId.isNotEmpty) {
            query = query.eq('customer_id', userId);
          }

          final data = await query.maybeSingle();
          if (data == null) {
            return null;
          }

          return Map<String, dynamic>.from(data);
        },
        requireSession: true,
      );

      if (row == null) {
        return null;
      }

      return _hydrateOrder(row);
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
    String orderId,
  ) async {
    try {
      final rows =
          await SessionManager.instance.runWithValidSession<List<dynamic>>(
        () => _client
            .from('order_items')
            .select('*')
            .eq('order_id', orderId)
            .order('created_at'),
        requireSession: true,
      );

      return _mapRows(rows);
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
    final rows =
        await SessionManager.instance.runWithValidSession<List<dynamic>>(
      () => _client
          .from('orders')
          .select('id')
          .eq('customer_id', userId)
          .inFilter('status', activeStatuses),
      requireSession: true,
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
        return await _createOrderViaRpc(input);
      } on PostgrestException catch (error) {
        if (_looksLikeMissingRpc(error)) {
          return _createOrderDirect(input);
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

    return orders
        .map(
          (order) => _attachRestaurantData(
            order,
            restaurantMap[_stringValue(order['restaurant_id']) ?? ''],
          ),
        )
        .toList(growable: false);
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
    return _attachRestaurantData(order, restaurantMap[restaurantId]);
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
    final orderRow = await SessionManager.instance
        .runWithValidSession<Map<String, dynamic>?>(
      () async {
        final data = await _client
            .from('orders')
            .insert({
              'restaurant_id': input.restaurantId,
              'receipt_number': receiptNumber,
              'status': 'pending',
              'total_price': input.totalPrice,
              'delivery_cost': input.deliveryCost,
              'address': input.address,
              'customer_name': input.customerName,
              'customer_phone': input.customerPhone,
              'customer_lat': input.customerLat,
              'customer_lng': input.customerLng,
            })
            .select('id')
            .single();

        return Map<String, dynamic>.from(data);
      },
      requireSession: true,
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
      await SessionManager.instance.runWithValidSession<void>(
        () async {
          await _client.from('orders').update({
            'user_id': userId,
            'total_price': totalPrice,
            'delivery_cost': deliveryCost,
          }).eq('id', orderId);
        },
        requireSession: true,
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
}
