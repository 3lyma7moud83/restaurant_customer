import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/services/error_logger.dart';
import 'session_manager.dart';

class ItemsService {
  static final _client = Supabase.instance.client;

  static void _ensureManager() {
    final role = _client.auth.currentUser?.userMetadata?['role'];
    if (role != 'manager') {
      throw Exception('Not authorized');
    }
  }

  static Future<List<Map<String, dynamic>>> fetchByCategory({
    required String categoryId,
  }) async {
    try {
      final res =
          await SessionManager.instance.runWithValidSession<List<dynamic>>(
        () => _client
            .from('items')
            .select()
            .eq('category_id', categoryId)
            .order('created_at', ascending: false),
      );
      if (res == null) {
        return const [];
      }

      return List<Map<String, dynamic>>.from(res);
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
  }
}
