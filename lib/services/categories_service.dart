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
            .select('id, name, image_url, created_at')
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
      final sortedCategories = _sortCategories(categories);
      _categoriesCache[cacheKey] = _CategoriesCacheEntry(
        value: sortedCategories,
        cachedAt: DateTime.now(),
      );
      return sortedCategories;
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'categories_service.getByManager',
        error: error,
        stack: stack,
      );
      throw Exception(ErrorLogger.userMessage);
    }
  }

  // Deterministic order for UI:
  // 1) created_at ascending (older first to preserve manager insertion order)
  // 2) localized name
  // 3) id fallback for stable ties
  static List<Map<String, dynamic>> _sortCategories(
    List<Map<String, dynamic>> source,
  ) {
    final next = List<Map<String, dynamic>>.from(source);
    next.sort((a, b) {
      final createdA = DateTime.tryParse((a['created_at'] ?? '').toString());
      final createdB = DateTime.tryParse((b['created_at'] ?? '').toString());
      if (createdA != null && createdB != null) {
        final byCreated = createdA.compareTo(createdB);
        if (byCreated != 0) {
          return byCreated;
        }
      } else if (createdA != null) {
        return -1;
      } else if (createdB != null) {
        return 1;
      }

      final nameA = (a['name'] ?? '').toString().trim().toLowerCase();
      final nameB = (b['name'] ?? '').toString().trim().toLowerCase();
      final byName = nameA.compareTo(nameB);
      if (byName != 0) {
        return byName;
      }

      final idA = (a['id'] ?? '').toString();
      final idB = (b['id'] ?? '').toString();
      return idA.compareTo(idB);
    });
    return next;
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
