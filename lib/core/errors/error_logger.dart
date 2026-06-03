import 'package:flutter/foundation.dart';

import 'app_error.dart';
import 'error_type.dart';

class ErrorLogFormatter {
  ErrorLogFormatter._();

  static void log(AppError error) {
    final level = _levelTag(error);
    final category = _categoryTag(error.type);
    final timestamp = error.createdAt.toUtc().toIso8601String();

    debugPrint(
      '[$level][$category][$timestamp] '
      'code=${error.code} module=${error.module} '
      'screen=${error.screen ?? '-'} action=${error.action ?? '-'} '
      'user=${error.userId ?? '-'} restaurant=${error.restaurantId ?? '-'} '
      'driver=${error.driverId ?? '-'} internet=${error.internetStatus}',
    );
    debugPrint(
      '[$level][$category][$timestamp] message=${error.message}',
    );
    if (error.stackTraceText != null && error.stackTraceText!.isNotEmpty) {
      debugPrint(
        '[$level][$category][$timestamp] stacktrace=${error.stackTraceText}',
      );
    }
  }

  static String _levelTag(AppError error) {
    switch (error.severity) {
      case ErrorSeverity.low:
        return 'WARNING';
      case ErrorSeverity.medium:
        return 'ERROR';
      case ErrorSeverity.high:
        return 'ERROR';
      case ErrorSeverity.critical:
        return 'CRITICAL';
    }
  }

  static String _categoryTag(ErrorType type) {
    switch (type) {
      case ErrorType.network:
      case ErrorType.timeout:
        return 'NETWORK';
      case ErrorType.realtime:
        return 'REALTIME';
      case ErrorType.auth:
        return 'AUTH';
      default:
        return 'ERROR';
    }
  }
}
