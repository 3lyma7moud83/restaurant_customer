import '../core/cache/local_reference_cache.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/services/error_logger.dart';
import 'session_manager.dart';

class CategoriesService {
  static final _client = Supabase.instance.client;
  static const Duration _cacheTtl = Duration(minutes: 5);
  static final _cache = LocalReferenceCache('customer_categories');
  static const int _defaultPageSize = 80;

  @visibleForTesting
  static bool isCacheFresh({
    required DateTime cachedAt,
    DateTime? now,
  }) {
    return !((now ?? DateTime.now()).difference(cachedAt) > _cacheTtl);
  }

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
    final user = _client.auth.currentUser?.id ?? 'anonymous';
    final key =
        '$restaurantId:$managerId:${page < 0 ? 0 : page}:${pageSize <= 0 ? _defaultPageSize : pageSize}';
    return _cache.read(
        scope: user,
        key: key,
        ttl: _cacheTtl,
        forceRefresh: forceRefresh,
        isCurrent: () => (_client.auth.currentUser?.id ?? 'anonymous') == user,
        load: () => _fetchByRestaurant(
            restaurantId: restaurantId,
            managerId: managerId,
            page: page,
            pageSize: pageSize));
  }

  static Future<List<Map<String, dynamic>>> _fetchByRestaurant(
      {required String restaurantId,
      String? managerId,
      required int page,
      required int pageSize}) async {
    final normalizedRestaurantId = restaurantId.trim();
    final normalizedManagerId = (managerId ?? '').trim();
    final safePageSize = pageSize <= 0 ? _defaultPageSize : pageSize;
    final from = page < 0 ? 0 : page * safePageSize;
    final to = from + safePageSize - 1;

    try {
      debugPrint(
        '[CategoriesService.getByRestaurantCached] query: restaurant_id=$normalizedRestaurantId, '
        'manager_id=$normalizedManagerId, range=$from:$to',
      );

      final managerIds = await _resolveManagerIdsForCategoryLookup(
        restaurantId: normalizedRestaurantId,
        managerId: normalizedManagerId,
      );
      if (managerIds.isEmpty) {
        debugPrint(
          '[CategoriesService.getByRestaurantCached] no manager_id could be resolved '
          'for restaurant_id=$normalizedRestaurantId manager_id=$normalizedManagerId',
        );
        return const [];
      }

      final res =
          await SessionManager.instance.runWithValidSession<List<dynamic>>(
        () {
          final query = _client
              .from('categories')
              .select('id, name, image_url, sort_order');
          final filteredQuery = managerIds.length == 1
              ? query.eq('manager_id', managerIds.first)
              : query.inFilter('manager_id', managerIds);
          return filteredQuery
              .order('sort_order', ascending: true)
              .range(from, to);
        },
      );
      if (res == null) {
        throw StateError('Category read unavailable');
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

  static Future<List<String>> _resolveManagerIdsForCategoryLookup({
    required String restaurantId,
    required String managerId,
  }) async {
    final resolved = <String>{};
    if (managerId.isNotEmpty) {
      resolved.add(managerId);
    }

    if (restaurantId.isNotEmpty) {
      resolved.add(restaurantId);
    }

    if (managerId.isNotEmpty) {
      return resolved.toList(growable: false);
    }

    final managerRows =
        await SessionManager.instance.runWithValidSession<List<dynamic>>(
      () => _client
          .from('managers')
          .select('user_id, restaurant_id')
          .or('restaurant_id.eq.$restaurantId,user_id.eq.$restaurantId')
          .limit(2),
    );

    if (managerRows != null) {
      for (final rawRow in managerRows.whereType<Map>()) {
        final row = Map<String, dynamic>.from(rawRow);
        final resolvedManagerId = _stringValue(row['user_id']);
        if (resolvedManagerId != null && resolvedManagerId.isNotEmpty) {
          resolved.add(resolvedManagerId);
        }
      }
    }

    return resolved.toList(growable: false);
  }

  static String? _stringValue(dynamic value) {
    final normalized = value?.toString().trim();
    if (normalized == null ||
        normalized.isEmpty ||
        normalized.toLowerCase() == 'null') {
      return null;
    }
    return normalized;
  }
}
