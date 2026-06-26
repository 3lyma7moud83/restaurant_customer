import 'dart:async';
import 'dart:convert';
import 'dart:math';

import '../core/stability/offline_order_queue_service.dart';
import '../core/stability/rpc_security_service.dart';
import '../core/stability/stability_logger.dart';
import '../core/stability/stability_metrics_service.dart';
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

class ActiveOrderInProgressException implements Exception {
  const ActiveOrderInProgressException({
    required this.orderId,
    this.message =
        'لديك طلب جاري بالفعل، لا يمكنك إنشاء طلب جديد حتى يتم إنهاؤه.',
  });

  final String orderId;
  final String message;

  @override
  String toString() => message;
}

class DuplicateOrderBlockedException implements Exception {
  const DuplicateOrderBlockedException([
    this.message =
        'يوجد طلب قيد المعالجة بالفعل. انتظر قليلًا قبل إعادة المحاولة.',
  ]);

  final String message;

  @override
  String toString() => message;
}

class OrderQueuedOfflineException implements Exception {
  const OrderQueuedOfflineException({
    required this.orderRequestToken,
    required this.checkoutSessionId,
    this.message = 'تم حفظ الطلب محليًا وسيتم إرساله عند عودة الاتصال.',
  });

  final String message;
  final String? orderRequestToken;
  final String? checkoutSessionId;

  @override
  String toString() => message;
}

class CreateOrderItemInput {
  const CreateOrderItemInput({
    required this.itemId,
    required this.name,
    required this.price,
    required this.quantity,
    this.variantId = '',
    this.variantName = '',
    double? variantPrice,
    this.note = '',
  }) : variantPrice = variantPrice ?? price;

  final String itemId;
  final String name;
  final double price;
  final int quantity;
  final String variantId;
  final String variantName;
  final double variantPrice;
  final String note;

  String get displayName {
    final normalizedVariantName = variantName.trim();
    if (normalizedVariantName.isEmpty) {
      return name;
    }
    return '$name ($normalizedVariantName)';
  }

  Map<String, dynamic> toRpcJson() {
    final normalizedNote = note.trim();
    final normalizedItemId = itemId.trim();
    final normalizedVariantId = variantId.trim();
    final normalizedVariantName = variantName.trim();
    return {
      if (normalizedItemId.isNotEmpty) 'item_id': normalizedItemId,
      'item_name': name,
      'item_display_name': displayName,
      'price': price,
      if (normalizedVariantId.isNotEmpty) 'variant_id': normalizedVariantId,
      if (normalizedVariantName.isNotEmpty)
        'variant_name': normalizedVariantName,
      if (normalizedVariantName.isNotEmpty) 'variant_price': variantPrice,
      'qty': quantity,
      'quantity': quantity,
      if (normalizedNote.isNotEmpty) 'note': normalizedNote,
      if (normalizedNote.isNotEmpty) 'notes': normalizedNote,
    };
  }

  Map<String, dynamic> toOrderItemInsert(
    String orderId, {
    bool includeItemId = true,
    bool includeVariantFields = true,
    bool useDisplayName = false,
  }) {
    final normalizedNote = note.trim();
    final normalizedItemId = itemId.trim();
    final normalizedVariantId = variantId.trim();
    final normalizedVariantName = variantName.trim();
    return {
      'order_id': orderId,
      if (includeItemId && normalizedItemId.isNotEmpty)
        'item_id': normalizedItemId,
      'item_name': useDisplayName ? displayName : name,
      'price': price,
      'qty': quantity,
      'quantity': quantity,
      if (includeVariantFields && normalizedVariantId.isNotEmpty)
        'variant_id': normalizedVariantId,
      if (includeVariantFields && normalizedVariantName.isNotEmpty)
        'variant_name': normalizedVariantName,
      if (includeVariantFields && normalizedVariantName.isNotEmpty)
        'variant_price': variantPrice,
      if (normalizedNote.isNotEmpty) 'notes': normalizedNote,
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
    this.buildingNumber = '',
    this.apartmentNumber = '',
    this.floorNumber = '',
    this.landmark = '',
    this.notes = '',
    this.paymentMethod,
    this.orderRequestToken,
    this.checkoutSessionId,
    this.paymentReferenceId,
    this.reconciliationStatus,
    this.verificationAttempts,
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
  final String buildingNumber;
  final String apartmentNumber;
  final String floorNumber;
  final String landmark;
  final String notes;
  // Reserved for upcoming online payment integrations (e.g. Stripe).
  final String? paymentMethod;
  final String? orderRequestToken;
  final String? checkoutSessionId;
  final String? paymentReferenceId;
  final String? reconciliationStatus;
  final int? verificationAttempts;
  final List<CreateOrderItemInput> items;

  Map<String, dynamic> toQueuePayload() {
    return {
      'user_id': userId,
      'restaurant_id': restaurantId,
      'customer_name': customerName,
      'customer_phone': customerPhone,
      'address': address,
      'building_number': buildingNumber,
      'apartment_number': apartmentNumber,
      'floor_number': floorNumber,
      'landmark': landmark,
      'notes': notes,
      'customer_lat': customerLat,
      'customer_lng': customerLng,
      'latitude': customerLat,
      'longitude': customerLng,
      'total_price': totalPrice,
      'delivery_cost': deliveryCost,
      'payment_method': paymentMethod,
      'order_request_token': orderRequestToken,
      'checkout_session_id': checkoutSessionId,
      'payment_reference_id': paymentReferenceId,
      'reconciliation_status': reconciliationStatus,
      'verification_attempts': verificationAttempts,
      'items': items.map((item) => item.toRpcJson()).toList(growable: false),
    };
  }

  static CreateOrderInput fromQueuePayload(Map<String, dynamic> payload) {
    final itemMaps = (payload['items'] as List? ?? const <dynamic>[])
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList(growable: false);

    return CreateOrderInput(
      userId: _stringValue(payload['user_id']) ?? '',
      restaurantId: _stringValue(payload['restaurant_id']) ?? '',
      customerName: _stringValue(payload['customer_name']) ?? '',
      customerPhone: _stringValue(payload['customer_phone']) ?? '',
      address: _stringValue(payload['address']) ?? '',
      buildingNumber: _stringValue(payload['building_number']) ?? '',
      apartmentNumber: _stringValue(payload['apartment_number']) ?? '',
      floorNumber: _stringValue(payload['floor_number']) ?? '',
      landmark: _stringValue(payload['landmark']) ?? '',
      notes: _stringValue(payload['notes']) ?? '',
      customerLat:
          _toDouble(payload['customer_lat'] ?? payload['latitude']) ?? 0,
      customerLng:
          _toDouble(payload['customer_lng'] ?? payload['longitude']) ?? 0,
      totalPrice: _toDouble(payload['total_price']) ?? 0,
      deliveryCost: _toDouble(payload['delivery_cost']) ?? 0,
      paymentMethod: _stringValue(payload['payment_method']),
      orderRequestToken: _stringValue(payload['order_request_token']),
      checkoutSessionId: _stringValue(payload['checkout_session_id']),
      paymentReferenceId: _stringValue(payload['payment_reference_id']),
      reconciliationStatus: _stringValue(payload['reconciliation_status']),
      verificationAttempts:
          (_toDouble(payload['verification_attempts']) ?? 0).round(),
      items: itemMaps
          .map(
            (item) => CreateOrderItemInput(
              itemId: _stringValue(item['item_id']) ?? '',
              name: _stringValue(item['item_name']) ?? '',
              price: _toDouble(item['price']) ?? 0,
              quantity:
                  (_toDouble(item['qty'] ?? item['quantity']) ?? 1).round(),
              variantId: _stringValue(item['variant_id']) ?? '',
              variantName: _stringValue(item['variant_name']) ?? '',
              variantPrice: _toDouble(item['variant_price'] ?? item['price']),
              note: _stringValue(item['notes'] ?? item['note']) ?? '',
            ),
          )
          .toList(growable: false),
    );
  }

  static String? _stringValue(dynamic value) {
    final text = value?.toString().trim();
    if (text == null || text.isEmpty || text == 'null') {
      return null;
    }
    return text;
  }

  static double? _toDouble(dynamic value) {
    if (value is num) {
      return value.toDouble();
    }
    if (value is String) {
      return double.tryParse(value);
    }
    return null;
  }
}

class OrdersService {
  OrdersService._();

  static final SupabaseClient _client = Supabase.instance.client;
  static const Duration _cacheTtl = Duration(seconds: 30);
  static const Duration _deliveryConfirmationRequestTimeout =
      Duration(seconds: 15);
  static final Map<String, _OrderCacheEntry<List<Map<String, dynamic>>>>
      _customerOrdersCache = {};
  static final Map<String, _OrderCacheEntry<Map<String, dynamic>>> _orderCache =
      {};
  static final Map<String, _OrderCacheEntry<List<Map<String, dynamic>>>>
      _orderItemsCache = {};
  static final Set<String> _inFlightOrderRequestTokens = <String>{};
  static final Map<String, DateTime> _lastCheckoutAttemptAtByUser =
      <String, DateTime>{};
  static bool _offlineQueueInitialized = false;

  static final List<String> activeStatuses =
      blockingActiveOrderStatuses.toList(growable: false);

  static const List<String> _customerRelationTables = [
    'customers',
    'profiles',
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

      final rows =
          await SessionManager.instance.runWithValidSession<List<dynamic>>(
        () => _client
            .from('orders')
            .select(_orderSelect)
            .eq('customer_id', userId)
            .order('created_at', ascending: false),
        requireSession: true,
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

  static Future<Map<String, dynamic>?> getLatestActiveOrder(
    String userId, {
    bool forceRefresh = false,
  }) async {
    try {
      final row = await SessionManager.instance
          .runWithValidSession<Map<String, dynamic>?>(() async {
        final result = await _client
            .from('orders')
            .select(_orderSelect)
            .eq('customer_id', userId)
            .inFilter('status', activeStatuses)
            .order('created_at', ascending: false)
            .limit(1)
            .maybeSingle();
        if (result == null) {
          return null;
        }
        return Map<String, dynamic>.from(result);
      }, requireSession: true);

      if (row == null) {
        return null;
      }

      final hydrated = await _hydrateOrder(row);
      _writeOrderCache(hydrated);
      if (forceRefresh) {
        _customerOrdersCache.remove(userId.trim());
      }
      return hydrated;
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'orders_service.getLatestActiveOrder',
        error: error,
        stack: stack,
      );
      throw Exception(ErrorLogger.userMessage);
    }
  }

  static Future<void> confirmDeliveryReceived(
    Map<String, dynamic> order,
  ) async {
    final orderId = idOf(order);
    if (orderId.isEmpty) {
      throw const PostgrestException(message: 'order_id_required');
    }

    final authoritativeStateVersion = authoritativeStateVersionOf(order);
    final orderVersion = orderVersionOf(order);

    try {
      await _runDeliveryConfirmationRpc(
        'confirm_delivery_received',
        params: {
          'p_order_id': orderId,
          'p_authoritative_state_version': authoritativeStateVersion,
          'p_order_version': orderVersion,
        },
      );
      StabilityLogger.deliveryConfirmation(
        'Customer Confirmed Delivery order=$orderId '
        'authoritative_state_version=${authoritativeStateVersion ?? '-'} '
        'order_version=${orderVersion ?? '-'}',
      );
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'orders_service.confirmDeliveryReceived',
        action: orderId,
        error: error,
        stack: stack,
      );
      throw Exception(_deliveryConfirmationUserMessage(error));
    }
  }

  static Future<void> reportDeliveryIssue(
    Map<String, dynamic> order, {
    required String reason,
  }) async {
    final orderId = idOf(order);
    final normalizedReason = reason.trim();
    if (orderId.isEmpty) {
      throw const PostgrestException(message: 'order_id_required');
    }
    if (normalizedReason.isEmpty) {
      throw const PostgrestException(message: 'delivery_issue_reason_required');
    }

    final authoritativeStateVersion = authoritativeStateVersionOf(order);
    final orderVersion = orderVersionOf(order);

    try {
      await _runDeliveryConfirmationRpc(
        'report_delivery_issue',
        params: {
          'p_order_id': orderId,
          'p_reason': normalizedReason,
          'p_authoritative_state_version': authoritativeStateVersion,
          'p_order_version': orderVersion,
        },
      );
      StabilityLogger.deliveryConfirmation(
        'Customer Reported Delivery Issue order=$orderId '
        'reason=$normalizedReason '
        'authoritative_state_version=${authoritativeStateVersion ?? '-'} '
        'order_version=${orderVersion ?? '-'}',
      );
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'orders_service.reportDeliveryIssue',
        action: orderId,
        error: error,
        stack: stack,
      );
      throw Exception(_deliveryConfirmationUserMessage(error));
    }
  }

  static Future<String> createOrder(
    CreateOrderInput input, {
    bool allowOfflineQueue = true,
  }) async {
    await _ensureOfflineQueueInitialized();

    final userId = input.userId.trim();
    final requestToken = _resolvedRequestToken(input);
    final inFlightKey = '$userId::$requestToken';
    if (_inFlightOrderRequestTokens.contains(inFlightKey)) {
      StabilityMetricsService.instance.increment(
        'duplicate_order_attempts',
        module: 'orders_service',
      );
      throw const DuplicateOrderBlockedException();
    }

    final now = DateTime.now();
    final lastAttemptAt = _lastCheckoutAttemptAtByUser[userId];
    if (lastAttemptAt != null &&
        now.difference(lastAttemptAt) < const Duration(milliseconds: 900)) {
      StabilityMetricsService.instance.increment(
        'duplicate_order_attempts',
        module: 'orders_service',
      );
      throw const DuplicateOrderBlockedException();
    }
    _lastCheckoutAttemptAtByUser[userId] = now;
    _inFlightOrderRequestTokens.add(inFlightKey);

    try {
      final existingOrderId = await _resolveCompletedOrderFromRequestToken(
        userId: userId,
        orderRequestToken: requestToken,
      );
      if (existingOrderId != null) {
        StabilityLogger.checkout(
          'Idempotent checkout hit user=$userId token=$requestToken order=$existingOrderId',
        );
        return existingOrderId;
      }

      await _reserveOrderRequestToken(input, requestToken);

      final blockingOrder = await getLatestActiveOrder(
        input.userId,
        forceRefresh: true,
      );
      if (blockingOrder != null) {
        await _markOrderRequestTokenFailed(
          userId: userId,
          orderRequestToken: requestToken,
          reason: 'active_order_exists',
        );
        throw ActiveOrderInProgressException(
          orderId: idOf(blockingOrder),
        );
      }

      final effectiveInput = input.orderRequestToken == requestToken
          ? input
          : CreateOrderInput(
              userId: input.userId,
              restaurantId: input.restaurantId,
              customerName: input.customerName,
              customerPhone: input.customerPhone,
              address: input.address,
              customerLat: input.customerLat,
              customerLng: input.customerLng,
              totalPrice: input.totalPrice,
              deliveryCost: input.deliveryCost,
              buildingNumber: input.buildingNumber,
              apartmentNumber: input.apartmentNumber,
              floorNumber: input.floorNumber,
              landmark: input.landmark,
              notes: input.notes,
              paymentMethod: input.paymentMethod,
              orderRequestToken: requestToken,
              checkoutSessionId: input.checkoutSessionId,
              paymentReferenceId: input.paymentReferenceId,
              reconciliationStatus: input.reconciliationStatus,
              verificationAttempts: input.verificationAttempts,
              items: input.items,
            );

      try {
        final orderId = await _createOrderViaRpc(effectiveInput);
        _customerOrdersCache.remove(input.userId.trim());
        await _markOrderRequestTokenCompleted(
          userId: userId,
          orderRequestToken: requestToken,
          orderId: orderId,
        );
        return orderId;
      } on PostgrestException catch (error) {
        if (_looksLikeMissingRpc(error)) {
          final orderId = await _createOrderDirect(effectiveInput);
          _customerOrdersCache.remove(input.userId.trim());
          await _markOrderRequestTokenCompleted(
            userId: userId,
            orderRequestToken: requestToken,
            orderId: orderId,
          );
          return orderId;
        }
        rethrow;
      }
    } on OrderLimitExceededException {
      rethrow;
    } on ActiveOrderInProgressException {
      rethrow;
    } on DuplicateOrderBlockedException {
      rethrow;
    } catch (error, stack) {
      final isTransient = _isTransientOrderSubmissionError(error);
      if (allowOfflineQueue && isTransient) {
        await _markOrderRequestTokenQueued(
          userId: userId,
          orderRequestToken: requestToken,
        );
        await OfflineOrderQueueService.instance.enqueue({
          ...input.toQueuePayload(),
          'user_id': input.userId,
          'order_request_token': requestToken,
          'checkout_session_id': input.checkoutSessionId,
          'payment_reference_id': input.paymentReferenceId,
          'attempts': 0,
        });
        StabilityMetricsService.instance.increment(
          'offline_queue_enqueued',
          module: 'orders_service',
        );
        throw OrderQueuedOfflineException(
          orderRequestToken: requestToken,
          checkoutSessionId: input.checkoutSessionId,
        );
      }

      await _markOrderRequestTokenFailed(
        userId: userId,
        orderRequestToken: requestToken,
        reason: error.toString(),
      );
      await ErrorLogger.logError(
        module: 'orders_service.createOrder',
        error: error,
        stack: stack,
      );
      throw Exception(ErrorLogger.userMessage);
    } finally {
      _inFlightOrderRequestTokens.remove(inFlightKey);
    }
  }

  static Future<void> _ensureOfflineQueueInitialized() async {
    if (_offlineQueueInitialized) {
      return;
    }
    _offlineQueueInitialized = true;
    try {
      await OfflineOrderQueueService.instance.initialize(
        submitter: (payload) async {
          final queuedInput = CreateOrderInput.fromQueuePayload(payload);
          return createOrder(
            queuedInput,
            allowOfflineQueue: false,
          );
        },
      );
      StabilityLogger.offlineQueue('Offline order queue initialized.');
    } catch (error, stack) {
      _offlineQueueInitialized = false;
      await ErrorLogger.logError(
        module: 'orders_service.ensureOfflineQueueInitialized',
        error: error,
        stack: stack,
      );
      rethrow;
    }
  }

  static String _resolvedRequestToken(CreateOrderInput input) {
    final existing = input.orderRequestToken?.trim();
    if (existing != null && existing.isNotEmpty) {
      return existing;
    }
    final random = Random.secure();
    final epoch = DateTime.now().toUtc().microsecondsSinceEpoch;
    final noise = random.nextInt(1 << 30).toRadixString(16);
    return 'ord-$epoch-$noise';
  }

  static Future<String?> _resolveCompletedOrderFromRequestToken({
    required String userId,
    required String orderRequestToken,
  }) async {
    final token = orderRequestToken.trim();
    if (token.isEmpty) {
      return null;
    }

    try {
      final row = await SessionManager.instance
          .runWithValidSession<Map<String, dynamic>?>(
        () async {
          final result = await _client
              .from('order_request_tokens')
              .select('status, order_id')
              .eq('user_id', userId)
              .eq('order_request_token', token)
              .limit(1)
              .maybeSingle();
          if (result == null) {
            return null;
          }
          return Map<String, dynamic>.from(result);
        },
        requireSession: true,
      );

      final status = row?['status']?.toString().trim().toLowerCase() ?? '';
      final orderId = row?['order_id']?.toString().trim();
      if (orderId != null &&
          orderId.isNotEmpty &&
          (status == 'completed' ||
              status == 'confirmed' ||
              status == 'processing')) {
        return orderId;
      }
    } on PostgrestException catch (error) {
      if (!_isSchemaMismatchError(error)) {
        rethrow;
      }
    }

    return _resolveOrderIdFromOrdersTableByToken(
      userId: userId,
      orderRequestToken: token,
    );
  }

  static Future<void> _reserveOrderRequestToken(
    CreateOrderInput input,
    String orderRequestToken,
  ) async {
    try {
      final existing = await SessionManager.instance
          .runWithValidSession<Map<String, dynamic>?>(
        () async {
          final row = await _client
              .from('order_request_tokens')
              .select('status, order_id, attempts, updated_at')
              .eq('user_id', input.userId)
              .eq('order_request_token', orderRequestToken)
              .limit(1)
              .maybeSingle();
          if (row == null) {
            return null;
          }
          return Map<String, dynamic>.from(row);
        },
        requireSession: true,
      );

      final now = DateTime.now().toUtc();
      final currentStatus =
          existing?['status']?.toString().trim().toLowerCase() ?? '';
      final currentOrderId = existing?['order_id']?.toString().trim() ?? '';
      final updatedAt = DateTime.tryParse(
        existing?['updated_at']?.toString() ?? '',
      )?.toUtc();

      if ((currentStatus == 'pending' || currentStatus == 'processing') &&
          currentOrderId.isEmpty &&
          updatedAt != null &&
          now.difference(updatedAt) < const Duration(seconds: 25)) {
        StabilityMetricsService.instance.increment(
          'duplicate_order_attempts',
          module: 'orders_service',
          payload: {'guard': 'pending_order_token'},
        );
        throw const DuplicateOrderBlockedException();
      }

      final attempts =
          int.tryParse(existing?['attempts']?.toString() ?? '') ?? 0;
      final payload = <String, dynamic>{
        'user_id': input.userId,
        'order_request_token': orderRequestToken,
        'status': 'processing',
        'attempts': attempts + 1,
        'restaurant_id': input.restaurantId,
        'total_amount': input.totalPrice,
        'payment_method': input.paymentMethod,
        'checkout_session_id': input.checkoutSessionId,
        'payment_reference_id': input.paymentReferenceId,
        'reconciliation_status': input.reconciliationStatus ?? 'pending',
        'verification_attempts': input.verificationAttempts ?? 0,
        'last_error': null,
        'order_id': currentOrderId.isEmpty ? null : currentOrderId,
        'expires_at':
            now.add(const Duration(hours: 2)).toUtc().toIso8601String(),
      };

      await SessionManager.instance.runWithValidSession<void>(
        () async {
          await _client.from('order_request_tokens').upsert(
                payload,
                onConflict: 'user_id,order_request_token',
              );
        },
        requireSession: true,
      );
    } on PostgrestException catch (error) {
      if (_isSchemaMismatchError(error)) {
        return;
      }
      rethrow;
    }
  }

  static Future<void> _markOrderRequestTokenCompleted({
    required String userId,
    required String orderRequestToken,
    required String orderId,
  }) async {
    await _updateOrderRequestTokenStatus(
      userId: userId,
      orderRequestToken: orderRequestToken,
      payload: {
        'status': 'completed',
        'order_id': orderId,
        'last_error': null,
      },
    );
  }

  static Future<void> _markOrderRequestTokenQueued({
    required String userId,
    required String orderRequestToken,
  }) async {
    await _updateOrderRequestTokenStatus(
      userId: userId,
      orderRequestToken: orderRequestToken,
      payload: {
        'status': 'queued_offline',
      },
    );
  }

  static Future<void> _markOrderRequestTokenFailed({
    required String userId,
    required String orderRequestToken,
    required String reason,
  }) async {
    await _updateOrderRequestTokenStatus(
      userId: userId,
      orderRequestToken: orderRequestToken,
      payload: {
        'status': 'failed',
        'last_error': reason,
      },
    );
  }

  static Future<void> _updateOrderRequestTokenStatus({
    required String userId,
    required String orderRequestToken,
    required Map<String, dynamic> payload,
  }) async {
    try {
      await SessionManager.instance.runWithValidSession<void>(
        () async {
          await _client
              .from('order_request_tokens')
              .update({
                ...payload,
                'updated_at': DateTime.now().toUtc().toIso8601String(),
              })
              .eq('user_id', userId)
              .eq('order_request_token', orderRequestToken);
        },
        requireSession: true,
      );
    } on PostgrestException catch (error) {
      if (_isSchemaMismatchError(error)) {
        return;
      }
      rethrow;
    }
  }

  static bool _isTransientOrderSubmissionError(Object error) {
    if (error is TimeoutException) {
      return true;
    }
    if (error is PostgrestException) {
      final message = error.message.toLowerCase();
      if (message.contains('timed out') ||
          message.contains('timeout') ||
          message.contains('connection') ||
          message.contains('failed host lookup') ||
          message.contains('temporarily unavailable') ||
          message.contains('status code 429') ||
          message.contains('status code 500') ||
          message.contains('status code 502') ||
          message.contains('status code 503') ||
          message.contains('status code 504')) {
        return true;
      }
    }
    final normalized = error.toString().toLowerCase();
    return normalized.contains('network') ||
        normalized.contains('socket') ||
        normalized.contains('connection') ||
        normalized.contains('timed out') ||
        normalized.contains('timeout') ||
        normalized.contains('failed host lookup') ||
        normalized.contains('temporarily unavailable');
  }

  static Future<dynamic> _runDeliveryConfirmationRpc(
    String rpcName, {
    required Map<String, dynamic> params,
  }) {
    return SessionManager.instance.runWithValidSession<dynamic>(
      () => _client
          .rpc(
            rpcName,
            params: params,
          )
          .timeout(_deliveryConfirmationRequestTimeout),
      requireSession: true,
    );
  }

  static String _deliveryConfirmationUserMessage(Object error) {
    final normalized = error.toString().toLowerCase();

    if (_isTransientOrderSubmissionError(error)) {
      return 'تعذر الاتصال بالسيرفر. تحقق من الاتصال وحاول مرة أخرى دون تغيير حالة الطلب.';
    }

    if (normalized.contains('stale_order_state') ||
        normalized.contains('version_conflict') ||
        normalized.contains('40001')) {
      return 'تم تحديث الطلب من السيرفر. انتظر تحديث الحالة الرسمي ثم حاول مرة أخرى.';
    }

    if (normalized.contains('invalid_order_state')) {
      return 'لا يمكن تنفيذ تأكيد الاستلام على الحالة الحالية للطلب.';
    }

    if (normalized.contains('function') ||
        normalized.contains('could not find') ||
        normalized.contains('does not exist')) {
      return 'خدمة تأكيد الاستلام غير متاحة حالياً. حاول مرة أخرى لاحقاً.';
    }

    return 'تعذر تنفيذ الطلب حالياً. حاول مرة أخرى دون تغيير حالة الطلب.';
  }

  static Future<String?> _resolveOrderIdFromOrdersTableByToken({
    required String userId,
    required String orderRequestToken,
  }) async {
    final row = await SessionManager.instance
        .runWithValidSession<Map<String, dynamic>?>(
      () async {
        final data = await _client
            .from('orders')
            .select('id')
            .eq('order_request_token', orderRequestToken)
            .eq('customer_id', userId)
            .order('created_at', ascending: false)
            .limit(1)
            .maybeSingle();
        if (data == null) {
          return null;
        }
        return Map<String, dynamic>.from(data);
      },
      requireSession: true,
    );
    final resolved = _stringValue(row?['id']);
    return resolved == null || resolved.isEmpty ? null : resolved;
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

  static int? authoritativeStateVersionOf(Map<String, dynamic> order) {
    return _intValue(order['authoritative_state_version']);
  }

  static int? orderVersionOf(Map<String, dynamic> order) {
    return _intValue(order['order_version']);
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
    String? buildingNumber,
    String? apartmentNumber,
    String? floorNumber,
    String? landmark,
  }) {
    final normalizedAddress = address.trim();
    final resolvedBuilding = (buildingNumber?.trim().isNotEmpty == true
            ? buildingNumber
            : houseNumber)
        ?.trim();
    final details = <String>[
      if (resolvedBuilding != null && resolvedBuilding.isNotEmpty)
        'رقم العمارة: $resolvedBuilding',
      if ((apartmentNumber ?? '').trim().isNotEmpty)
        'رقم الشقة: ${apartmentNumber!.trim()}',
      if ((floorNumber ?? '').trim().isNotEmpty)
        'الدور: ${floorNumber!.trim()}',
      if ((landmark ?? '').trim().isNotEmpty)
        'علامة مميزة: ${landmark!.trim()}',
    ];
    if (details.isEmpty) {
      return normalizedAddress;
    }
    return '$normalizedAddress - ${details.join(' - ')}';
  }

  static String customerNameOf(Map<String, dynamic> order) {
    final customer = customerDataOf(order);
    return _stringValue(order['customer_name']) ??
        _firstStringValue(customer, const [
          'name',
          'full_name',
          'customer_name',
        ]) ??
        _stringValue(order['name']) ??
        'العميل';
  }

  static String? customerPhoneOf(Map<String, dynamic> order) {
    final customer = customerDataOf(order);
    return _stringValue(order['customer_phone']) ??
        _firstStringValue(customer, const [
          'phone',
          'mobile',
          'phone_number',
          'mobile_number',
          'customer_phone',
        ]) ??
        _stringValue(order['phone']);
  }

  static String? customerIdOf(Map<String, dynamic> order) {
    return _stringValue(order['customer_id']);
  }

  static Map<String, dynamic>? customerDataOf(Map<String, dynamic> order) {
    final hydrated = order['customer_data'];
    if (hydrated is Map) {
      return Map<String, dynamic>.from(hydrated);
    }

    for (final key in const ['customer', 'customers', 'profile', 'profiles']) {
      final value = order[key];
      if (value is Map) {
        return Map<String, dynamic>.from(value);
      }
      if (value is List && value.isNotEmpty && value.first is Map) {
        return Map<String, dynamic>.from(value.first as Map);
      }
    }

    return null;
  }

  static double? customerLatOf(Map<String, dynamic> order) {
    return toDouble(order['customer_lat']) ??
        toDouble(order['latitude']) ??
        toDouble(order['delivery_lat']) ??
        toDouble(order['destination_lat']) ??
        toDouble(order['lat']) ??
        _coordinateFromDynamic(order['delivery_location'], isLatitude: true) ??
        _coordinateFromDynamic(order['destination'], isLatitude: true) ??
        _coordinateFromDynamic(order['customer_location'], isLatitude: true) ??
        _coordinateFromDynamic(order['google_order'], isLatitude: true);
  }

  static double? customerLngOf(Map<String, dynamic> order) {
    return toDouble(order['customer_lng']) ??
        toDouble(order['longitude']) ??
        toDouble(order['delivery_lng']) ??
        toDouble(order['destination_lng']) ??
        toDouble(order['lng']) ??
        _coordinateFromDynamic(order['delivery_location'], isLatitude: false) ??
        _coordinateFromDynamic(order['destination'], isLatitude: false) ??
        _coordinateFromDynamic(order['customer_location'], isLatitude: false) ??
        _coordinateFromDynamic(order['google_order'], isLatitude: false);
  }

  static double? driverLatOf(Map<String, dynamic> order) {
    return toDouble(order['driver_lat']) ??
        toDouble(order['courier_lat']) ??
        toDouble(order['rider_lat']) ??
        _coordinateFromDynamic(order['driver_location'], isLatitude: true);
  }

  static double? driverLngOf(Map<String, dynamic> order) {
    return toDouble(order['driver_lng']) ??
        toDouble(order['courier_lng']) ??
        toDouble(order['rider_lng']) ??
        _coordinateFromDynamic(order['driver_location'], isLatitude: false);
  }

  static String? driverIdOf(Map<String, dynamic> order) {
    return _stringValue(order['driver_id']) ??
        _stringValue(order['courier_id']) ??
        _stringValue(order['rider_id']);
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

  static String restaurantAddressOf(Map<String, dynamic> order) {
    final restaurant = restaurantDataOf(order);
    if (restaurant != null) {
      return RestaurantsService.restaurantAddressOf(restaurant);
    }

    return _stringValue(order['restaurant_address']) ??
        _stringValue(order['restaurant_full_address']) ??
        _stringValue(order['restaurant_location_address']) ??
        _stringValue(order['restaurant_street_address']) ??
        'العنوان غير متوفر';
  }

  static String deliveryDetailsOf(Map<String, dynamic> order) {
    final details = <String>[
      ..._deliveryDetailsFromMap(order),
      ..._deliveryDetailsFromDynamic(order['address_details']),
      ..._deliveryDetailsFromDynamic(order['delivery_details_data']),
      ..._deliveryDetailsFromDynamic(order['delivery_address_data']),
      ..._deliveryDetailsFromDynamic(order['customer_address']),
      ..._deliveryDetailsFromDynamic(order['customer_address_data']),
    ];

    final uniqueDetails = <String>[];
    final seenDetails = <String>{};
    for (final detail in details) {
      if (seenDetails.add(detail)) {
        uniqueDetails.add(detail);
      }
    }

    if (uniqueDetails.isEmpty) {
      return 'لا توجد تفاصيل إضافية.';
    }

    return uniqueDetails.join(' - ');
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
    final value = toDouble(item['qty']) ?? toDouble(item['quantity']) ?? 0;
    return value.round();
  }

  static String itemNameOf(Map<String, dynamic> item) {
    final name =
        _stringValue(item['item_name']) ?? _stringValue(item['name']) ?? 'عنصر';
    final variantName =
        _stringValue(item['variant_name'] ?? item['variantName']);
    if (variantName == null || variantName.isEmpty) {
      return name;
    }
    if (name.contains('($variantName)')) {
      return name;
    }
    return '$name ($variantName)';
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
    final customerIds = orders
        .map(customerIdOf)
        .whereType<String>()
        .where((id) => id.isNotEmpty)
        .toList(growable: false);
    final restaurantMap =
        await RestaurantsService.getOrderRestaurantsByIds(restaurantIds);
    final customerMap = await _loadCustomerRelationsByIds(customerIds);

    final hydratedOrders = orders
        .map(
          (order) => _attachHydratedData(
            order,
            restaurant:
                restaurantMap[_stringValue(order['restaurant_id']) ?? ''],
            customer: customerMap[customerIdOf(order) ?? ''],
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
    final customerId = customerIdOf(order) ?? '';

    Map<String, dynamic>? restaurant;
    if (restaurantId.isNotEmpty) {
      final restaurantMap =
          await RestaurantsService.getOrderRestaurantsByIds([restaurantId]);
      restaurant = restaurantMap[restaurantId];
    }

    Map<String, dynamic>? customer;
    if (customerId.isNotEmpty) {
      final customerMap = await _loadCustomerRelationsByIds([customerId]);
      customer = customerMap[customerId];
    }

    final hydrated = _attachHydratedData(
      order,
      restaurant: restaurant,
      customer: customer,
    );
    _writeOrderCache(hydrated);
    return hydrated;
  }

  static Map<String, dynamic> _attachHydratedData(
    Map<String, dynamic> order, {
    Map<String, dynamic>? restaurant,
    Map<String, dynamic>? customer,
  }) {
    if (restaurant == null && customer == null) {
      return Map<String, dynamic>.from(order);
    }

    return <String, dynamic>{
      ...order,
      if (restaurant != null) 'restaurant_data': restaurant,
      if (customer != null) 'customer_data': customer,
    };
  }

  static Future<String> _createOrderViaRpc(CreateOrderInput input) async {
    final replayKey =
        'create_order_with_items:${input.userId}:${input.orderRequestToken ?? input.checkoutSessionId ?? '-'}';
    if (!RpcSecurityService.instance.allowLocalAction(
      replayKey,
      window: const Duration(seconds: 3),
    )) {
      StabilityMetricsService.instance.increment(
        'replay_rejection_count',
        module: 'orders_service',
        payload: {'rpc': 'create_order_with_items'},
      );
      throw const DuplicateOrderBlockedException();
    }
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
      input: input,
    );
    await _synchronizeCreatedOrderItems(
      orderId: orderId,
      input: input,
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

    await _insertOrderItemsWithFallback(
      orderId: orderId,
      items: input.items,
    );

    await _synchronizeCreatedOrder(
      orderId: orderId,
      input: input,
    );

    return orderId;
  }

  static Future<void> _insertOrderItemsWithFallback({
    required String orderId,
    required List<CreateOrderItemInput> items,
  }) async {
    if (items.isEmpty) {
      return;
    }

    final fullPayloads = items
        .map((item) => item.toOrderItemInsert(orderId))
        .toList(growable: false);
    final payloadsWithoutVariantColumns = items
        .map(
          (item) => item.toOrderItemInsert(
            orderId,
            includeItemId: false,
            includeVariantFields: false,
            useDisplayName: true,
          ),
        )
        .toList(growable: false);
    final variants = [
      _orderItemPayloadsWithout(payloadsWithoutVariantColumns, const {
        'quantity',
        'notes',
      }),
      payloadsWithoutVariantColumns,
      _orderItemPayloadsWithout(payloadsWithoutVariantColumns, const {
        'quantity',
      }),
      _orderItemPayloadsWithout(payloadsWithoutVariantColumns, const {'notes'}),
      fullPayloads,
      _orderItemPayloadsWithout(fullPayloads, const {'quantity'}),
      _orderItemPayloadsWithout(fullPayloads, const {'notes'}),
      _orderItemPayloadsWithout(fullPayloads, const {'quantity', 'notes'}),
    ];

    PostgrestException? lastSchemaError;
    for (final payloads in variants) {
      try {
        await SessionManager.instance.runWithValidSession<void>(
          () async {
            await _client.from('order_items').insert(payloads);
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

  static List<Map<String, dynamic>> _orderItemPayloadsWithout(
    List<Map<String, dynamic>> payloads,
    Set<String> columns,
  ) {
    return payloads
        .map(
          (payload) => Map<String, dynamic>.from(payload)
            ..removeWhere((key, _) => columns.contains(key)),
        )
        .toList(growable: false);
  }

  static Future<void> _synchronizeCreatedOrderItems({
    required String orderId,
    required CreateOrderInput input,
  }) async {
    if (input.items.isEmpty) {
      return;
    }

    try {
      final rows =
          await SessionManager.instance.runWithValidSession<List<dynamic>>(
        () => _client.from('order_items').select('*').eq('order_id', orderId),
        requireSession: true,
      );
      final existingRows = _mapRows(rows).toList(growable: true);
      if (existingRows.isEmpty) {
        return;
      }

      for (final item in input.items) {
        if (existingRows.isEmpty) {
          return;
        }
        final matchedIndex = existingRows.indexWhere(
          (row) {
            final rowName = itemNameOf(row);
            return (rowName == item.name || rowName == item.displayName) &&
                (itemPriceOf(row) - item.price).abs() < 0.01 &&
                quantityOfItem(row) == item.quantity;
          },
        );
        final fallbackIndex = matchedIndex >= 0 ? matchedIndex : 0;
        final row = existingRows.removeAt(fallbackIndex);
        final itemId = itemIdOf(row);
        if (itemId.isEmpty) {
          continue;
        }

        final hasSynchronizableDetails = item.note.trim().isNotEmpty ||
            item.variantId.trim().isNotEmpty ||
            item.variantName.trim().isNotEmpty;
        if (!hasSynchronizableDetails) {
          continue;
        }

        await _updateOrderItemRowWithFallback(
          itemId: itemId,
          item: item,
        );
      }
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'orders_service.synchronizeCreatedOrderItems',
        error: error,
        stack: stack,
      );
    }
  }

  static Future<void> _updateOrderItemRowWithFallback({
    required String itemId,
    required CreateOrderItemInput item,
  }) async {
    final note = item.note.trim();
    final normalizedMenuItemId = item.itemId.trim();
    final normalizedVariantId = item.variantId.trim();
    final normalizedVariantName = item.variantName.trim();
    final fullPayload = {
      'quantity': item.quantity,
      if (normalizedMenuItemId.isNotEmpty) 'item_id': normalizedMenuItemId,
      if (normalizedVariantId.isNotEmpty) 'variant_id': normalizedVariantId,
      if (normalizedVariantName.isNotEmpty)
        'variant_name': normalizedVariantName,
      if (normalizedVariantName.isNotEmpty) 'variant_price': item.variantPrice,
      if (note.isNotEmpty) 'notes': note,
    };
    final payloadWithoutVariantColumns = Map<String, dynamic>.from(fullPayload)
      ..removeWhere(
        (key, _) => const {
          'item_id',
          'variant_id',
          'variant_name',
          'variant_price',
        }.contains(key),
      );
    final variants = [
      fullPayload,
      if (note.isNotEmpty)
        Map<String, dynamic>.from(fullPayload)..remove('quantity'),
      Map<String, dynamic>.from(fullPayload)..remove('notes'),
      payloadWithoutVariantColumns,
      if (note.isNotEmpty)
        Map<String, dynamic>.from(payloadWithoutVariantColumns)
          ..remove('quantity'),
      Map<String, dynamic>.from(payloadWithoutVariantColumns)..remove('notes'),
    ].where((payload) => payload.isNotEmpty).toList(growable: false);

    for (final payload in variants) {
      try {
        await SessionManager.instance.runWithValidSession<void>(
          () async {
            await _client.from('order_items').update(payload).eq('id', itemId);
          },
          requireSession: true,
        );
        return;
      } on PostgrestException catch (error) {
        if (_isSchemaMismatchError(error)) {
          continue;
        }
        rethrow;
      }
    }
  }

  static Future<void> _synchronizeCreatedOrder({
    required String orderId,
    required CreateOrderInput input,
  }) async {
    try {
      await _updateOrderRowWithFallback(
        orderId: orderId,
        payloads: _buildOrderSynchronizationPayloads(
          input: input,
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

  static Future<Map<String, dynamic>?> _fetchOrderRow({
    required String orderId,
    String? userId,
  }) async {
    final effectiveUserId =
        _stringValue(userId) ?? _client.auth.currentUser?.id;
    if (effectiveUserId == null || effectiveUserId.isEmpty) {
      return null;
    }

    return SessionManager.instance.runWithValidSession<Map<String, dynamic>?>(
      () async {
        final row = await _client
            .from('orders')
            .select(_orderSelect)
            .eq('id', orderId)
            .eq('customer_id', effectiveUserId)
            .limit(1)
            .maybeSingle();
        if (row == null) {
          return null;
        }
        return Map<String, dynamic>.from(row);
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
    final legacyDetailPayload = _orderAddressColumnPayload(input);
    final currentSchemaPayload = {
      ...basePayload,
      'customer_id': input.userId,
      'total': input.totalPrice,
      'items_total': max(0, input.totalPrice - input.deliveryCost),
      'lat': input.customerLat,
      'lng': input.customerLng,
      'items': input.items.map((item) => item.toRpcJson()).toList(),
    };

    final normalizedPayloads = [
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
    ];

    return [
      currentSchemaPayload,
      Map<String, dynamic>.from(currentSchemaPayload)..remove('items_total'),
      ...normalizedPayloads.map(
        (payload) => {
          ...payload,
          ...legacyDetailPayload,
        },
      ),
      ...normalizedPayloads,
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
    required CreateOrderInput input,
  }) {
    final detailPayload = _orderAddressColumnPayload(input);
    final metadataPayload = <String, dynamic>{
      if (input.orderRequestToken != null &&
          input.orderRequestToken!.trim().isNotEmpty)
        'order_request_token': input.orderRequestToken!.trim(),
      if (input.checkoutSessionId != null &&
          input.checkoutSessionId!.trim().isNotEmpty)
        'checkout_session_id': input.checkoutSessionId!.trim(),
      if (input.paymentReferenceId != null &&
          input.paymentReferenceId!.trim().isNotEmpty)
        'payment_reference_id': input.paymentReferenceId!.trim(),
      if (input.reconciliationStatus != null &&
          input.reconciliationStatus!.trim().isNotEmpty)
        'reconciliation_status': input.reconciliationStatus!.trim(),
      if (input.verificationAttempts != null)
        'verification_attempts': input.verificationAttempts,
      if (input.paymentMethod != null && input.paymentMethod!.trim().isNotEmpty)
        'payment_method': input.paymentMethod!.trim(),
    };
    final metadataPayloadWithoutPaymentMethod = Map<String, dynamic>.from(
      metadataPayload,
    )..remove('payment_method');
    final currentSchemaPayload = <String, dynamic>{
      'customer_id': input.userId,
      'total': input.totalPrice,
      'items_total': max(0, input.totalPrice - input.deliveryCost),
      'delivery_cost': input.deliveryCost,
      'items': input.items.map((item) => item.toRpcJson()).toList(),
    };

    final normalizedPayloads = [
      {
        'customer_id': input.userId,
        'total_price': input.totalPrice,
        'delivery_cost': input.deliveryCost,
      },
      {
        'customer_id': input.userId,
        'total': input.totalPrice,
        'delivery_cost': input.deliveryCost,
      },
    ];

    return [
      {
        ...currentSchemaPayload,
        ...metadataPayloadWithoutPaymentMethod,
      },
      currentSchemaPayload,
      ...normalizedPayloads.map(
        (base) => {
          ...base,
          ...detailPayload,
          ...metadataPayload,
        },
      ),
      ...normalizedPayloads.map(
        (base) => {
          ...base,
          ...detailPayload,
        },
      ),
      ...normalizedPayloads,
    ];
  }

  static Map<String, dynamic> _orderAddressColumnPayload(
    CreateOrderInput input,
  ) {
    final buildingNumber = input.buildingNumber.trim();
    final apartmentNumber = input.apartmentNumber.trim();
    final floorNumber = input.floorNumber.trim();
    final landmark = input.landmark.trim();
    final notes = input.notes.trim();

    return {
      'address': input.address,
      'customer_name': input.customerName,
      'customer_phone': input.customerPhone,
      'building_number': buildingNumber,
      'apartment_number': apartmentNumber,
      'floor_number': floorNumber,
      'landmark': landmark,
      'notes': notes,
      'latitude': input.customerLat,
      'longitude': input.customerLng,
      'address_details': {
        'address': input.address,
        'building_number': buildingNumber,
        'apartment_number': apartmentNumber,
        'floor_number': floorNumber,
        'landmark': landmark,
        'notes': notes,
        'latitude': input.customerLat,
        'longitude': input.customerLng,
      },
    };
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

  static Future<Map<String, Map<String, dynamic>>> _loadCustomerRelationsByIds(
    Iterable<String> customerIds,
  ) async {
    final requestedIds = customerIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (requestedIds.isEmpty) {
      return const <String, Map<String, dynamic>>{};
    }

    final relations = <String, Map<String, dynamic>>{};

    for (final table in _customerRelationTables) {
      try {
        final rows =
            await SessionManager.instance.runWithValidSession<List<dynamic>>(
          () {
            final query = _client.from(table).select('*');
            if (requestedIds.length == 1) {
              return query.eq('id', requestedIds.first);
            }
            return query.inFilter('id', requestedIds);
          },
          requireSession: true,
        );

        for (final row in _mapRows(rows)) {
          final customerId = _stringValue(row['id']);
          if (customerId == null || customerId.isEmpty) {
            continue;
          }
          if (!requestedIds.contains(customerId)) {
            continue;
          }

          final existing = relations[customerId];
          relations[customerId] = existing == null
              ? row
              : {
                  ...row,
                  ...existing,
                };
        }
      } on PostgrestException {
        continue;
      } catch (_) {
        continue;
      }
    }

    return relations;
  }

  static String? _stringValue(dynamic value) {
    final text = value?.toString().trim();
    if (text == null || text.isEmpty || text == 'null') {
      return null;
    }
    return text;
  }

  static int? _intValue(dynamic value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    final text = _stringValue(value);
    if (text == null) {
      return null;
    }
    return int.tryParse(text);
  }

  static double? _coordinateFromDynamic(
    dynamic source, {
    required bool isLatitude,
  }) {
    if (source == null) {
      return null;
    }

    if (source is Map) {
      return _coordinateFromMap(
        Map<String, dynamic>.from(source),
        isLatitude: isLatitude,
      );
    }

    if (source is String) {
      final text = source.trim();
      if (text.isEmpty) {
        return null;
      }

      final direct = toDouble(text);
      if (direct != null) {
        return direct;
      }

      try {
        final decoded = jsonDecode(text);
        return _coordinateFromDynamic(decoded, isLatitude: isLatitude);
      } catch (_) {
        return null;
      }
    }

    return null;
  }

  static List<String> _deliveryDetailsFromDynamic(dynamic value) {
    if (value is Map) {
      return _deliveryDetailsFromMap(Map<String, dynamic>.from(value));
    }
    if (value is String) {
      final normalized = value.trim();
      if (normalized.isEmpty || normalized.toLowerCase() == 'null') {
        return const [];
      }
      try {
        final decoded = jsonDecode(normalized);
        if (decoded is Map) {
          return _deliveryDetailsFromMap(Map<String, dynamic>.from(decoded));
        }
      } catch (_) {
        // Keep raw text fallback when the value is not JSON.
      }
      return [normalized];
    }
    return const [];
  }

  static List<String> _deliveryDetailsFromMap(Map<String, dynamic> source) {
    final details = <String>[];
    final direct = _firstStringValue(source, const [
      'delivery_details',
      'delivery_note',
      'delivery_notes',
      'note',
      'notes',
      'additional_notes',
      'special_instructions',
      'instructions',
    ]);
    if (direct != null) {
      details.add(direct);
    }

    final house = _firstStringValue(source, const [
      'house_apartment_no',
      'building_number',
      'house_number',
      'building',
    ]);
    if (house != null) {
      details.add('رقم المبنى/الشقة: $house');
    }

    final floor = _firstStringValue(source, const [
      'floor_number',
      'floor',
      'level',
    ]);
    if (floor != null) {
      details.add('الدور: $floor');
    }

    final apartment = _firstStringValue(source, const [
      'apartment_number',
      'apartment',
      'flat',
      'unit',
      'apartment_no',
      'unit_number',
    ]);
    if (apartment != null) {
      details.add('الشقة: $apartment');
    }

    final area = _firstStringValue(source, const ['area', 'district']);
    if (area != null) {
      details.add('المنطقة: $area');
    }

    final landmark = _firstStringValue(source, const ['landmark']);
    if (landmark != null) {
      details.add('علامة مميزة: $landmark');
    }

    final seen = <String>{};
    final unique = <String>[];
    for (final detail in details) {
      if (seen.add(detail)) {
        unique.add(detail);
      }
    }
    return unique;
  }

  static String? _firstStringValue(
    Map<String, dynamic>? source,
    List<String> keys,
  ) {
    if (source == null) {
      return null;
    }
    for (final key in keys) {
      final value = _stringValue(source[key]);
      if (value != null) {
        return value;
      }
    }
    return null;
  }

  static double? _coordinateFromMap(
    Map<String, dynamic> source, {
    required bool isLatitude,
  }) {
    final axisKeys = isLatitude
        ? const [
            'lat',
            'latitude',
            'customer_lat',
            'delivery_lat',
            'destination_lat',
          ]
        : const [
            'lng',
            'lon',
            'longitude',
            'customer_lng',
            'delivery_lng',
            'destination_lng',
          ];

    for (final key in axisKeys) {
      final value = toDouble(source[key]);
      if (value != null) {
        return value;
      }
    }

    final geoJson = source['geometry'];
    if (geoJson is Map) {
      final coords = geoJson['coordinates'];
      if (coords is List && coords.length >= 2) {
        final value = isLatitude ? toDouble(coords[1]) : toDouble(coords[0]);
        if (value != null) {
          return value;
        }
      }
    }

    for (final nestedKey in const [
      'location',
      'coordinates',
      'destination',
      'delivery_location',
      'address',
    ]) {
      final nested = _coordinateFromDynamic(
        source[nestedKey],
        isLatitude: isLatitude,
      );
      if (nested != null) {
        return nested;
      }
    }

    return null;
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
