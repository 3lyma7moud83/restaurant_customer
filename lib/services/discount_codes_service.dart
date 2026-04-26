import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/services/error_logger.dart';
import 'session_manager.dart';

enum DiscountType {
  percentage,
  fixed,
}

enum DiscountCodeFailure {
  emptyCode,
  codeNotFound,
  inactive,
  belowMinimumOrder,
  unsupportedType,
  invalidDiscountValue,
}

class DiscountCodeValidationException implements Exception {
  const DiscountCodeValidationException(
    this.failure, {
    this.minimumOrderPrice,
  });

  final DiscountCodeFailure failure;
  final double? minimumOrderPrice;
}

class AppliedDiscountCode {
  const AppliedDiscountCode({
    required this.id,
    required this.restaurantId,
    required this.code,
    required this.type,
    required this.discountPercent,
    required this.discountAmount,
    required this.minOrderPrice,
  });

  final String id;
  final String restaurantId;
  final String code;
  final DiscountType type;
  final double discountPercent;
  final double discountAmount;
  final double minOrderPrice;

  String get normalizedCode => code.trim().toLowerCase();

  bool meetsMinimum(double subtotal) {
    return subtotal >= minOrderPrice;
  }

  double valueForSubtotal(double subtotal) {
    if (!subtotal.isFinite || subtotal <= 0) {
      return 0;
    }

    if (type == DiscountType.percentage) {
      final value = subtotal * (discountPercent / 100);
      return value.clamp(0, subtotal).toDouble();
    }
    return discountAmount.clamp(0, subtotal).toDouble();
  }
}

class DiscountCodesService {
  DiscountCodesService._();

  static final SupabaseClient _client = Supabase.instance.client;
  static const String _select = '''
      id,
      restaurant_id,
      code,
      discount_percent,
      discount_type,
      discount_amount,
      min_order_price,
      is_active,
      created_at
    ''';

  static Future<AppliedDiscountCode> validateCode({
    required String restaurantId,
    required String code,
    required double orderSubtotal,
  }) async {
    final normalizedRestaurantId = restaurantId.trim();
    final normalizedCode = code.trim();
    if (normalizedCode.isEmpty) {
      throw const DiscountCodeValidationException(
          DiscountCodeFailure.emptyCode);
    }
    if (normalizedRestaurantId.isEmpty) {
      throw const DiscountCodeValidationException(
        DiscountCodeFailure.codeNotFound,
      );
    }

    try {
      final rows =
          await SessionManager.instance.runWithValidSession<List<dynamic>>(
        () => _client
            .from('discount_codes')
            .select(_select)
            .eq('restaurant_id', normalizedRestaurantId)
            .ilike('code', normalizedCode)
            .order('created_at', ascending: false),
        requireSession: true,
      );

      final matchingRows = rows
          ?.whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .where(
            (row) =>
                (_stringValue(row['code']) ?? '').toLowerCase() ==
                normalizedCode.toLowerCase(),
          )
          .toList(growable: false);

      if (matchingRows == null || matchingRows.isEmpty) {
        throw const DiscountCodeValidationException(
          DiscountCodeFailure.codeNotFound,
        );
      }

      final row = matchingRows.first;
      final isActive = row['is_active'] == true;
      if (!isActive) {
        throw const DiscountCodeValidationException(
            DiscountCodeFailure.inactive);
      }

      final minOrderPrice = _toDouble(row['min_order_price']) ?? 0;
      if (orderSubtotal < minOrderPrice) {
        throw DiscountCodeValidationException(
          DiscountCodeFailure.belowMinimumOrder,
          minimumOrderPrice: minOrderPrice,
        );
      }

      final discountType = _parseType(row['discount_type']);
      if (discountType == null) {
        throw const DiscountCodeValidationException(
          DiscountCodeFailure.unsupportedType,
        );
      }

      final discountPercent = _toDouble(row['discount_percent']) ?? 0;
      final discountAmount = _toDouble(row['discount_amount']) ?? 0;
      if (discountType == DiscountType.percentage) {
        if (!discountPercent.isFinite ||
            discountPercent <= 0 ||
            discountPercent > 100) {
          throw const DiscountCodeValidationException(
            DiscountCodeFailure.invalidDiscountValue,
          );
        }
      } else {
        if (!discountAmount.isFinite || discountAmount <= 0) {
          throw const DiscountCodeValidationException(
            DiscountCodeFailure.invalidDiscountValue,
          );
        }
      }

      return AppliedDiscountCode(
        id: _stringValue(row['id']) ?? '',
        restaurantId:
            _stringValue(row['restaurant_id']) ?? normalizedRestaurantId,
        code: _stringValue(row['code']) ?? normalizedCode,
        type: discountType,
        discountPercent: discountPercent,
        discountAmount: discountAmount,
        minOrderPrice: minOrderPrice,
      );
    } on DiscountCodeValidationException {
      rethrow;
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'discount_codes_service.validateCode',
        error: error,
        stack: stack,
      );
      throw Exception(ErrorLogger.userMessage);
    }
  }

  static DiscountType? _parseType(dynamic value) {
    final normalized = _stringValue(value)?.toLowerCase();
    if (normalized == 'percentage' || normalized == 'percent') {
      return DiscountType.percentage;
    }
    if (normalized == 'fixed' ||
        normalized == 'fixed_amount' ||
        normalized == 'amount') {
      return DiscountType.fixed;
    }
    return null;
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
