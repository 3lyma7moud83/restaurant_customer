import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/services/error_logger.dart';
import 'session_manager.dart';

class CategoriesService {
  static final _client = Supabase.instance.client;
  static const Duration _cacheTtl = Duration(minutes: 5);
  static final Map<String, _CategoriesCacheEntry> _categoriesCache = {};

  /// جلب الأنواع حسب المطعم (manager).
  static Future<List<Map<String, dynamic>>> getByManager(
    String managerId,
  ) {
    return getByManagerCached(
      managerId,
      forceRefresh: false,
    );
  }

  static Future<List<Map<String, dynamic>>> getByManagerCached(
    String managerId, {
    bool forceRefresh = false,
  }) async {
    try {
      final cacheKey = managerId.trim();
      final cached = forceRefresh ? null : _categoriesCache[cacheKey];
      if (cached != null && !cached.isExpired) {
        return cached.value;
      }

      final res =
          await SessionManager.instance.runWithValidSession<List<dynamic>>(
        () => _client
            .from('categories')
            .select('id, name, image_url')
            .eq('manager_id', managerId)
            .order('created_at'),
      );
      if (res == null) {
        return const [];
      }

      final categories = res
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList(growable: false);
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
