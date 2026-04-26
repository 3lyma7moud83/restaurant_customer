import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/services/error_logger.dart';
import 'session_manager.dart';

class ComplaintsService {
  ComplaintsService._();

  static final SupabaseClient _client = Supabase.instance.client;
  static const List<String> _orderOwnerColumns = [
    'customer_id',
    'user_id',
  ];

  static Future<void> submitComplaint({
    required String userId,
    required String title,
    required String description,
    String? restaurantId,
    String? orderId,
  }) async {
    final normalizedTitle = title.trim();
    final normalizedDescription = description.trim();
    final normalizedRestaurantId = restaurantId?.trim();
    final normalizedOrderId = orderId?.trim();

    if (normalizedTitle.isEmpty) {
      throw Exception('عنوان الشكوى مطلوب.');
    }
    if (normalizedTitle.length < 4) {
      throw Exception('عنوان الشكوى قصير جدًا.');
    }
    if (normalizedDescription.isEmpty) {
      throw Exception('وصف الشكوى مطلوب.');
    }
    if (normalizedDescription.length < 10) {
      throw Exception('وصف الشكوى قصير جدًا.');
    }

    try {
      await SessionManager.instance.runWithValidSession<void>(
        () async {
          final target = await _resolveComplaintTarget(
            userId: userId,
            preferredRestaurantId: normalizedRestaurantId,
            preferredOrderId: normalizedOrderId,
          );
          if (target.restaurantId.isEmpty) {
            throw StateError(
              'تعذر تحديد المطعم المرتبط بالشكوى. افتح قائمة مطعم أو اطلب منه أولًا ثم أعد المحاولة.',
            );
          }

          final createdAt = DateTime.now().toUtc().toIso8601String();
          await _insertComplaintWithSchemaFallback(
            userId: userId,
            restaurantId: target.restaurantId,
            title: normalizedTitle,
            description: normalizedDescription,
            createdAtIso: createdAt,
          );
        },
        requireSession: true,
      );
    } on StateError catch (error, stack) {
      await ErrorLogger.logError(
        module: 'complaints_service.submitComplaint.validation',
        error: error,
        stack: stack,
      );
      throw Exception(error.message);
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'complaints_service.submitComplaint',
        error: error,
        stack: stack,
      );
      throw Exception(ErrorLogger.userMessage);
    }
  }

  static Future<_ComplaintTarget> _resolveComplaintTarget({
    required String userId,
    String? preferredRestaurantId,
    String? preferredOrderId,
  }) async {
    final normalizedRestaurantId = preferredRestaurantId?.trim();
    final normalizedOrderId = preferredOrderId?.trim();

    if (normalizedRestaurantId != null && normalizedRestaurantId.isNotEmpty) {
      return _ComplaintTarget(
        restaurantId: normalizedRestaurantId,
        orderId: normalizedOrderId == null || normalizedOrderId.isEmpty
            ? null
            : normalizedOrderId,
      );
    }

    if (normalizedOrderId != null && normalizedOrderId.isNotEmpty) {
      final orderTarget = await _loadOrderTargetByOrderId(
        userId: userId,
        orderId: normalizedOrderId,
      );
      if (orderTarget != null) {
        return orderTarget;
      }
    }

    final latestTarget = await _loadLatestOrderTarget(userId: userId);
    if (latestTarget != null) {
      return latestTarget;
    }

    return const _ComplaintTarget(restaurantId: '');
  }

  static Future<_ComplaintTarget?> _loadOrderTargetByOrderId({
    required String userId,
    required String orderId,
  }) async {
    final normalizedOrderId = orderId.trim();
    if (normalizedOrderId.isEmpty) {
      return null;
    }

    for (final ownerColumn in _orderOwnerColumns) {
      final row = await _client
          .from('orders')
          .select('id, restaurant_id')
          .eq('id', normalizedOrderId)
          .eq(ownerColumn, userId)
          .maybeSingle();
      if (row is Map<String, dynamic>) {
        final target = _targetFromOrderRow(row);
        if (target != null) {
          return target;
        }
      }
    }
    return null;
  }

  static Future<_ComplaintTarget?> _loadLatestOrderTarget({
    required String userId,
  }) async {
    for (final ownerColumn in _orderOwnerColumns) {
      final row = await _client
          .from('orders')
          .select('id, restaurant_id, created_at')
          .eq(ownerColumn, userId)
          .order('created_at', ascending: false)
          .limit(1)
          .maybeSingle();
      if (row is Map<String, dynamic>) {
        final target = _targetFromOrderRow(row);
        if (target != null) {
          return target;
        }
      }
    }
    return null;
  }

  static _ComplaintTarget? _targetFromOrderRow(Map<String, dynamic> row) {
    final restaurantId = row['restaurant_id']?.toString().trim() ?? '';
    final orderId = row['id']?.toString().trim();
    if (restaurantId.isEmpty) {
      return null;
    }
    return _ComplaintTarget(
      restaurantId: restaurantId,
      orderId: orderId == null || orderId.isEmpty ? null : orderId,
    );
  }

  static Future<void> _insertComplaintWithSchemaFallback({
    required String userId,
    required String restaurantId,
    required String title,
    required String description,
    required String createdAtIso,
  }) async {
    final primaryPayload = <String, dynamic>{
      'customer_id': userId,
      'restaurant_id': restaurantId,
      'title': title,
      'description': description,
      'created_at': createdAtIso,
    };

    try {
      await _client.from('complaints').insert(primaryPayload);
      return;
    } on PostgrestException catch (primaryError, primaryStack) {
      if (!_shouldTryLegacyPayload(primaryError)) {
        rethrow;
      }

      await ErrorLogger.logError(
        module: 'complaints_service.insert.primary_schema_mismatch',
        error: primaryError,
        stack: primaryStack,
      );

      final legacyPayload = <String, dynamic>{
        'user_id': userId,
        'restaurant_id': restaurantId,
        'customer_name': _fallbackCustomerName(),
        'customer_phone': _fallbackCustomerPhone(),
        'complaint_title': title,
        'complaint_message': description,
        'created_at': createdAtIso,
      };
      await _client.from('complaints').insert(legacyPayload);
    }
  }

  static bool _shouldTryLegacyPayload(PostgrestException error) {
    final code = (error.code ?? '').trim();
    if (code == '42703' || code == '23502') {
      return true;
    }

    final message = [
      error.message,
      error.details,
      error.hint,
    ].whereType<String>().join(' ').toLowerCase();

    return message.contains('customer_id') ||
        message.contains('description') ||
        message.contains('title') ||
        message.contains('complaint_title') ||
        message.contains('complaint_message') ||
        message.contains('user_id') ||
        message.contains('customer_name') ||
        message.contains('customer_phone');
  }

  static String _fallbackCustomerName() {
    final user = _client.auth.currentUser;
    final metadata = user?.userMetadata;
    final candidates = [
      metadata?['name'],
      metadata?['full_name'],
      metadata?['display_name'],
      user?.email,
    ];
    for (final candidate in candidates) {
      final text = candidate?.toString().trim() ?? '';
      if (text.isNotEmpty) {
        return text;
      }
    }
    return 'عميل';
  }

  static String _fallbackCustomerPhone() {
    final user = _client.auth.currentUser;
    final metadata = user?.userMetadata;
    final candidates = [
      metadata?['phone'],
      user?.phone,
    ];
    for (final candidate in candidates) {
      final text = candidate?.toString().trim() ?? '';
      if (text.isNotEmpty) {
        return text;
      }
    }
    return '-';
  }
}

class _ComplaintTarget {
  const _ComplaintTarget({
    required this.restaurantId,
    this.orderId,
  });

  final String restaurantId;
  final String? orderId;
}
