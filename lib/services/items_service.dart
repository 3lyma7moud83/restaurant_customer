import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/services/error_logger.dart';
import 'session_manager.dart';

class ItemsService {
  static final _client = Supabase.instance.client;
  static const Duration _cacheTtl = Duration(minutes: 5);
  static final Map<String, _ItemsCacheEntry> _itemsCache = {};

  static void _ensureManager() {
    final role = _client.auth.currentUser?.userMetadata?['role'];
    if (role != 'manager') {
      throw Exception('Not authorized');
    }
  }

  static Future<List<Map<String, dynamic>>> fetchByCategory({
    required String categoryId,
    bool forceRefresh = false,
  }) async {
    try {
      final cacheKey = categoryId.trim();
      final cached = forceRefresh ? null : _itemsCache[cacheKey];
      if (cached != null && !cached.isExpired) {
        return cached.value;
      }

      final res =
          await SessionManager.instance.runWithValidSession<List<dynamic>>(
        () => _client
            .from('items')
            .select('id, name, price, image_url')
            .eq('category_id', categoryId)
            .order('created_at', ascending: false),
      );
      if (res == null) {
        return const [];
      }

      final items = res
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList(growable: false);
      _itemsCache[cacheKey] = _ItemsCacheEntry(
        value: items,
        cachedAt: DateTime.now(),
      );
      return items;
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'items_service.fetchByCategory',
        error: error,
        stack: stack,
      );
      throw Exception(ErrorLogger.userMessage);
    }
  }

  static Future<Map<String, dynamic>> addItem({
    required String categoryId,
    required String name,
    required num price,
    String? imageUrl,
  }) async {
    _ensureManager();
    final res =
        await SessionManager.instance.runWithValidSession<Map<String, dynamic>>(
      () async {
        final data = await _client
            .from('items')
            .insert({
              'category_id': categoryId,
              'name': name,
              'price': price,
              'image_url': imageUrl,
            })
            .select()
            .single();

        return Map<String, dynamic>.from(data);
      },
      requireSession: true,
    );
    if (res == null) {
      throw const SessionExpiredException();
    }

    _itemsCache.remove(categoryId.trim());
    return res;
  }

  static Future<void> updateItem({
    required String itemId,
    required String name,
    required num price,
  }) async {
    _ensureManager();
    final updated = await SessionManager.instance.runWithValidSession<bool>(
      () async {
        await _client.from('items').update({
          'name': name,
          'price': price,
        }).eq('id', itemId);
        return true;
      },
      requireSession: true,
    );
    if (updated != true) {
      throw const SessionExpiredException();
    }

    _itemsCache.clear();
  }

  static Future<void> updateItemImageUrl({
    required String itemId,
    required String imageUrl,
  }) async {
    _ensureManager();
    final updated = await SessionManager.instance.runWithValidSession<bool>(
      () async {
        await _client.from('items').update({
          'image_url': imageUrl,
        }).eq('id', itemId);
        return true;
      },
      requireSession: true,
    );
    if (updated != true) {
      throw const SessionExpiredException();
    }

    _itemsCache.clear();
  }

  static Future<void> deleteItem({
    required String itemId,
  }) async {
    _ensureManager();
    final deleted = await SessionManager.instance.runWithValidSession<bool>(
      () async {
        await _client.from('items').delete().eq('id', itemId);
        return true;
      },
      requireSession: true,
    );
    if (deleted != true) {
      throw const SessionExpiredException();
    }

    _itemsCache.clear();
  }
}

class _ItemsCacheEntry {
  const _ItemsCacheEntry({
    required this.value,
    required this.cachedAt,
  });

  final List<Map<String, dynamic>> value;
  final DateTime cachedAt;

  bool get isExpired =>
      DateTime.now().difference(cachedAt) > ItemsService._cacheTtl;
}
