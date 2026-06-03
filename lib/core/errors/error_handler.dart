import 'package:flutter/material.dart';

import 'app_error.dart';
import 'error_service.dart';
import 'error_type.dart';
import 'error_ui.dart';

class ErrorHandler {
  ErrorHandler._();

  static Future<AppError> handle({
    required Object error,
    StackTrace? stackTrace,
    required String module,
    String? screen,
    String? action,
    BuildContext? context,
    bool showToUser = true,
  }) async {
    final appError = await ErrorService.instance.capture(
      error: error,
      stackTrace: stackTrace,
      module: module,
      screen: screen,
      action: action,
      showUserMessage: false,
    );

    if (!showToUser) {
      return appError;
    }

    final presentationContext = context;
    if (presentationContext != null && !presentationContext.mounted) {
      return appError;
    }

    await _present(appError, context: presentationContext);
    return appError;
  }

  static Future<T?> runGuarded<T>({
    required Future<T> Function() action,
    required String module,
    String? screen,
    String? actionName,
    BuildContext? context,
    bool showToUser = true,
  }) async {
    try {
      return await action();
    } catch (error, stack) {
      await handle(
        error: error,
        stackTrace: stack,
        module: module,
        screen: screen,
        action: actionName,
        context: context,
        showToUser: showToUser,
      );
      return null;
    }
  }

  static Future<void> _present(
    AppError error, {
    BuildContext? context,
  }) async {
    switch (error.severity) {
      case ErrorSeverity.low:
      case ErrorSeverity.medium:
        ErrorUi.showSnackBar(message: error.userMessage);
        return;
      case ErrorSeverity.high:
        if (context != null && context.mounted) {
          await ErrorUi.showErrorDialog(
            context,
            message: error.userMessage,
            code: error.code,
          );
          return;
        }
        ErrorUi.showSnackBar(message: error.userMessage, code: error.code);
        return;
      case ErrorSeverity.critical:
        if (context != null && context.mounted) {
          await Navigator.of(context, rootNavigator: true).push<void>(
            MaterialPageRoute<void>(
              builder: (_) => CriticalErrorScreen(error: error),
            ),
          );
          return;
        }
        ErrorUi.showSnackBar(message: error.userMessage, code: error.code);
        return;
    }
  }
}
