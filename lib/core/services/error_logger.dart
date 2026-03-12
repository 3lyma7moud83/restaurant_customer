import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class ErrorLogger {
  ErrorLogger._();

  static const String appName = 'customer_app';
  static const String userMessage = 'حدث خطأ في البرنامج. حاول مرة أخرى لاحقًا';

  static final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey =
      GlobalKey<ScaffoldMessengerState>();

  static DateTime? _lastMessageAt;

  static Future<void> logError({
    required String module,
    required Object error,
    StackTrace? stack,
  }) async {
    try {
      final client = _client;
      if (client == null) {
        return;
      }

      await client.from('system_errors').insert({
        'app_name': appName,
        'module': module,
        'error_message': error.toString(),
        'stack_trace': stack?.toString(),
        'user_id': client.auth.currentUser?.id,
      });
    } catch (_) {}
  }

  static void showUserMessage([String message = userMessage]) {
    final messenger = scaffoldMessengerKey.currentState;
    if (messenger == null) {
      return;
    }

    final now = DateTime.now();
    final lastMessageAt = _lastMessageAt;
    if (lastMessageAt != null &&
        now.difference(lastMessageAt) < const Duration(seconds: 2)) {
      return;
    }

    _lastMessageAt = now;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  static SupabaseClient? get _client {
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }
}
