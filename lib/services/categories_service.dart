import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/services/error_logger.dart';
import 'session_manager.dart';

class CategoriesService {
  static final _client = Supabase.instance.client;
  static const Duration _cacheTtl = Duration(minutes: 5);
  static final Map<String, _CategoriesCacheEntry> _categoriesCache = {};
  static const int _defaultPageSize = 80;

  /// جلب الأنواع حسب المطعم (manager).
  static Future<List<Map<String, dynamic>>> getByManager(
    String managerId,
  ) {
    return getByRestaurantCached(
      restaurantId: managerId,
      managerId: managerId,
    );
  }

  static Future<List<Map<String, dynamic>>> getByManagerCached(
    String managerId, {
    bool forceRefresh = false,
  }) async {
    return getByRestaurantCached(
      restaurantId: managerId,
      managerId: managerId,
      forceRefresh: forceRefresh,
    );
  }

  static Future<List<Map<String, dynamic>>> getByRestaurantCached({
    required String restaurantId,
    String? managerId,
    bool forceRefresh = false,
    int page = 0,
    int pageSize = _defaultPageSize,
  }) async {
    final normalizedRestaurantId = restaurantId.trim();
    final normalizedManagerId = (managerId ?? '').trim();
    final safePageSize = pageSize <= 0 ? _defaultPageSize : pageSize;
    final from = page < 0 ? 0 : page * safePageSize;
    final to = from + safePageSize - 1;

    try {
      final cacheKey = '$normalizedRestaurantId::$normalizedManagerId';
      final cached = forceRefresh ? null : _categoriesCache[cacheKey];
      if (cached != null && !cached.isExpired) {
        return cached.value;
      }

      debugPrint(
        '[CategoriesService.getByRestaurantCached] query: restaurant_id=$normalizedRestaurantId, '
        'manager_id=$normalizedManagerId, range=$from:$to',
      );

      final res =
          await SessionManager.instance.runWithValidSession<List<dynamic>>(
        () async {
          try {
            var query = _client
                .from('categories')
                .select('id, name, image_url, sort_order');

            if (normalizedManagerId.isNotEmpty) {
              query = query.or(
                'restaurant_id.eq.$normalizedRestaurantId,manager_id.eq.$normalizedManagerId',
              );
            } else {
              query = query.eq('restaurant_id', normalizedRestaurantId);
            }
            return await query
                .order('sort_order', ascending: true)
                .range(from, to);
          } on PostgrestException catch (e) {
            final message = e.message.toLowerCase();
            final isRestaurantSchemaIssue =
                (e.code == '42703' || e.code == 'PGRST204') &&
                    message.contains('restaurant_id');
            if (!isRestaurantSchemaIssue) rethrow;

            var legacyQuery = _client
                .from('categories')
                .select('id, name, image_url, sort_order');
            if (normalizedManagerId.isNotEmpty) {
              legacyQuery = legacyQuery.eq('manager_id', normalizedManagerId);
            } else {
              legacyQuery =
                  legacyQuery.eq('manager_id', normalizedRestaurantId);
            }
            return await legacyQuery
                .order('sort_order', ascending: true)
                .range(from, to);
          }
        },
      );
      if (res == null) {
        return const [];
      }

      final categories = res
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList(growable: false);
      debugPrint(
        '[CategoriesService.getByRestaurantCached] response_count=${categories.length} '
        'restaurant_id=$normalizedRestaurantId manager_id=$normalizedManagerId',
      );

      if (categories.isEmpty) {
        debugPrint(
          '[CategoriesService.getByRestaurantCached] empty response reason: '
          'no_data OR wrong_filter OR RLS_blocker | restaurant_id=$normalizedRestaurantId',
        );
      }

      _categoriesCache[cacheKey] = _CategoriesCacheEntry(
        value: categories,
        cachedAt: DateTime.now(),
      );
      return categories;
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'categories_service.getByManager',
        error: error,
        stack: stack,
      );
      throw Exception(ErrorLogger.userMessage);
    }
  }
}

class _CategoriesCacheEntry {
  const _CategoriesCacheEntry({
    required this.value,
    required this.cachedAt,
  });

  final List<Map<String, dynamic>> value;
  final DateTime cachedAt;

  bool get isExpired =>
      DateTime.now().difference(cachedAt) > CategoriesService._cacheTtl;
}
