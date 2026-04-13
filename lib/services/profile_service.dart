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
    String? imageUrl,
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
          final payload = <String, dynamic>{
            'id': user.id,
            'name': name,
            'phone': phone,
          };
          if (imageUrl != null) {
            payload['image_url'] =
                imageUrl.trim().isEmpty ? null : imageUrl.trim();
          }

          await _supabase.from('customers').upsert(
                payload,
                onConflict: 'id',
              );
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

  Future<Map<String, dynamic>> syncProfileFromAuth({
    String? name,
    String? imageUrl,
  }) async {
    final session = await SessionManager.instance.ensureValidSession(
      requireSession: true,
    );
    final user = session?.user;
    if (user == null) {
      throw const SessionExpiredException();
    }

    final existing = await getOrCreateProfile();
    final resolvedName = _firstNonEmpty([
      name,
      user.userMetadata?['full_name']?.toString(),
      user.userMetadata?['name']?.toString(),
      existing['name']?.toString(),
    ]);
    final resolvedImage = _firstNonEmpty([
      imageUrl,
      user.userMetadata?['avatar_url']?.toString(),
      user.userMetadata?['picture']?.toString(),
      existing['image_url']?.toString(),
    ]);
    final currentPhone = (existing['phone'] ?? '').toString().trim();

    try {
      final result = await SessionManager.instance
          .runWithValidSession<Map<String, dynamic>>(
        () async {
          final payload = <String, dynamic>{
            'id': user.id,
            'name': resolvedName,
            'phone': currentPhone,
            'image_url': resolvedImage,
          };
          await _supabase.from('customers').upsert(payload, onConflict: 'id');
          return payload;
        },
        requireSession: true,
      );

      return result ?? existing;
    } on SessionExpiredException {
      rethrow;
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'profile_service.syncProfileFromAuth',
        error: error,
        stack: stack,
      );
      throw Exception(ErrorLogger.userMessage);
    }
  }

  String _firstNonEmpty(Iterable<String?> values) {
    for (final value in values) {
      final normalized = value?.trim();
      if (normalized != null && normalized.isNotEmpty && normalized != 'null') {
        return normalized;
      }
    }
    return '';
  }
}
