import 'package:flutter/material.dart';

import '../errors/error_service.dart';
import '../errors/error_ui.dart';

class ErrorLogger {
  ErrorLogger._();

  static const String appName = 'customer_app';
  static const String userMessage = 'حدث خطأ في البرنامج. حاول مرة أخرى لاحقًا';

  static GlobalKey<ScaffoldMessengerState> get scaffoldMessengerKey =>
      ErrorUi.scaffoldMessengerKey;

  static Future<void> initialize() {
    return ErrorService.instance.initialize(appName: appName);
  }

  static Future<void> logError({
    required String module,
    required Object error,
    StackTrace? stack,
    String? screen,
    String? action,
    bool showToUser = false,
  }) {
    return ErrorService.instance.capture(
      error: error,
      stackTrace: stack,
      module: module,
      screen: screen,
      action: action,
      showUserMessage: showToUser,
    );
  }

  static void showUserMessage([String message = userMessage, String? code]) {
    ErrorUi.showSnackBar(message: message, code: code);
  }
}
