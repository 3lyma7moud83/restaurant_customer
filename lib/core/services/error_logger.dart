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

      final errorText = _redactSecrets(error.toString());
      final stackText = stack == null ? null : _redactSecrets(stack.toString());

      await client.from('system_errors').insert({
        'app_name': appName,
        'module': module,
        'error_message': errorText,
        'stack_trace': stackText,
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

  static String _redactSecrets(String input) {
    var output = input;

    // Common query param used by Mapbox URLs and others.
    output = output.replaceAllMapped(
      RegExp(r'(access_token=)([^&\s]+)', caseSensitive: false),
      (m) => '${m.group(1)}<redacted>',
    );

    // JWT-like tokens (including Supabase anon keys).
    output = output.replaceAllMapped(
      RegExp(r'eyJ[a-zA-Z0-9_-]*\.[a-zA-Z0-9_-]+\.[a-zA-Z0-9_-]+'),
      (_) => '<redacted.jwt>',
    );

    // Mapbox public tokens typically start with `pk.`.
    output = output.replaceAllMapped(
      RegExp(r'pk\.[a-zA-Z0-9_-]+\.[a-zA-Z0-9_-]+'),
      (_) => '<redacted.mapbox>',
    );

    return output;
  }
}
