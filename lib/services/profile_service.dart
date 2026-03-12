import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/services/error_logger.dart';
import 'session_manager.dart';

class ProfileService {
  final SupabaseClient _supabase = Supabase.instance.client;

  Future<Map<String, dynamic>> getOrCreateProfile() async {
    final session = await SessionManager.instance.ensureValidSession();
    final user = session?.user;

    if (user == null) {
      return {
        'name': '',
        'phone': '',
        'image_url': null,
      };
    }

    try {
      final data = await SessionManager.instance
          .runWithValidSession<Map<String, dynamic>>(
        () async {
          final row = await _supabase
              .from('customers')
              .select('name, phone, image_url')
              .eq('id', user.id)
              .maybeSingle();

          if (row != null) {
            return Map<String, dynamic>.from(row);
          }

          await _supabase.from('customers').upsert({
            'id': user.id,
            'name': '',
            'phone': '',
            'image_url': null,
          }, onConflict: 'id');

          return {
            'name': '',
            'phone': '',
            'image_url': null,
          };
        },
        requireSession: true,
      );

      if (data != null) {
        return data;
      }
    } on SessionExpiredException {
      rethrow;
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'profile_service.getOrCreateProfile',
        error: error,
        stack: stack,
      );
      throw Exception(ErrorLogger.userMessage);
    }

    return {
      'name': '',
      'phone': '',
      'image_url': null,
    };
  }

  Future<void> updateProfile({
    required String name,
    required String phone,
  }) async {
    try {
      final session = await SessionManager.instance.ensureValidSession(
        requireSession: true,
      );
      final user = session?.user;
      if (user == null) {
        throw const SessionExpiredException();
      }

      final updated = await SessionManager.instance.runWithValidSession<bool>(
        () async {
          await _supabase.from('customers').upsert({
            'id': user.id,
            'name': name,
            'phone': phone,
          }, onConflict: 'id');
          return true;
        },
        requireSession: true,
      );

      if (updated != true) {
        throw const SessionExpiredException();
      }
    } on SessionExpiredException {
      rethrow;
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'profile_service.updateProfile',
        error: error,
        stack: stack,
      );
      throw Exception(ErrorLogger.userMessage);
    }
  }
}
