import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/services/error_logger.dart';
import 'session_manager.dart';

class CategoriesService {
  static final _client = Supabase.instance.client;

  /// جلب الأنواع حسب المطعم (manager).
  static Future<List<Map<String, dynamic>>> getByManager(
    String managerId,
  ) async {
    try {
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

      return List<Map<String, dynamic>>.from(res);
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
