import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'error_codes.dart';
import 'error_type.dart';

class ErrorMappingResult {
  const ErrorMappingResult({
    required this.code,
    required this.type,
    required this.severity,
    required this.userMessage,
    required this.developerMessage,
  });

  final String code;
  final ErrorType type;
  final ErrorSeverity severity;
  final String userMessage;
  final String developerMessage;
}

class ErrorMapper {
  ErrorMapper._();

  static ErrorMappingResult map({
    required Object error,
    required String module,
    String? action,
  }) {
    final moduleHint = '$module ${action ?? ''}'.toLowerCase();
    final rawMessage = _normalizeWhitespace(error.toString());
    final normalized = rawMessage.toLowerCase();

    if (error is TimeoutException || _looksLikeTimeout(normalized)) {
      return ErrorMappingResult(
        code: ErrorCodes.networkTimeout,
        type: ErrorType.timeout,
        severity: ErrorSeverity.medium,
        userMessage: 'السيرفر يستجيب ببطء، حاول مرة أخرى.',
        developerMessage: rawMessage,
      );
    }

    if (error is AuthException) {
      final status = (error.statusCode ?? '').trim();
      final message = error.message.toLowerCase();
      final isExpired = status == '401' ||
          status == '403' ||
          _isSessionExpiredMessage(message);
      return ErrorMappingResult(
        code: isExpired
            ? ErrorCodes.authSessionExpired
            : ErrorCodes.authUnauthorized,
        type: ErrorType.auth,
        severity: isExpired ? ErrorSeverity.high : ErrorSeverity.medium,
        userMessage: isExpired
            ? 'انتهت الجلسة، سجل الدخول مرة أخرى.'
            : 'تعذر التحقق من الحساب. تأكد من بيانات الدخول.',
        developerMessage: rawMessage,
      );
    }

    if (error is PostgrestException) {
      final merged = [
        error.code,
        error.message,
        error.details?.toString(),
        error.hint,
      ].whereType<String>().join(' ').toLowerCase();

      if (_isDuplicateKey(error.code, merged)) {
        return ErrorMappingResult(
          code: ErrorCodes.databaseDuplicateKey,
          type: ErrorType.database,
          severity: ErrorSeverity.medium,
          userMessage: 'الحساب موجود بالفعل.',
          developerMessage: rawMessage,
        );
      }

      if (_isUnauthorizedCode(error.code) || _isSessionExpiredMessage(merged)) {
        return ErrorMappingResult(
          code: ErrorCodes.authSessionExpired,
          type: ErrorType.auth,
          severity: ErrorSeverity.high,
          userMessage: 'انتهت الجلسة، سجل الدخول مرة أخرى.',
          developerMessage: rawMessage,
        );
      }

      if (_isPermissionDenied(error.code, merged)) {
        return ErrorMappingResult(
          code: ErrorCodes.permissionDenied,
          type: ErrorType.permission,
          severity: ErrorSeverity.high,
          userMessage: 'ليس لديك صلاحية لتنفيذ هذا الإجراء.',
          developerMessage: rawMessage,
        );
      }

      if (_looksLikeValidationError(error.code, merged)) {
        return ErrorMappingResult(
          code: ErrorCodes.validationInvalidInput,
          type: ErrorType.validation,
          severity: ErrorSeverity.medium,
          userMessage:
              'البيانات المدخلة غير صحيحة. راجع الحقول وحاول مرة أخرى.',
          developerMessage: rawMessage,
        );
      }

      return ErrorMappingResult(
        code: ErrorCodes.databaseFailure,
        type: ErrorType.database,
        severity: ErrorSeverity.high,
        userMessage: 'حدث خطأ أثناء الاتصال بقاعدة البيانات. حاول مرة أخرى.',
        developerMessage: rawMessage,
      );
    }

    if (_looksLikeRealtimeError(moduleHint, normalized)) {
      return ErrorMappingResult(
        code: ErrorCodes.realtimeFailure,
        type: ErrorType.realtime,
        severity: ErrorSeverity.high,
        userMessage: 'انقطع التحديث اللحظي. جاري إعادة الاتصال تلقائيًا.',
        developerMessage: rawMessage,
      );
    }

    if (_looksLikeNotificationError(moduleHint, normalized)) {
      return ErrorMappingResult(
        code: ErrorCodes.notificationFailure,
        type: ErrorType.notification,
        severity: ErrorSeverity.medium,
        userMessage: 'تعذر تهيئة الإشعارات الآن. يمكنك المحاولة لاحقًا.',
        developerMessage: rawMessage,
      );
    }

    if (_looksLikeNetworkError(normalized)) {
      return ErrorMappingResult(
        code: ErrorCodes.networkNoInternet,
        type: ErrorType.network,
        severity: ErrorSeverity.medium,
        userMessage: 'لا يوجد اتصال بالإنترنت.',
        developerMessage: rawMessage,
      );
    }

    if (error is FormatException || _looksLikeParsingError(normalized)) {
      return ErrorMappingResult(
        code: ErrorCodes.parsingFailure,
        type: ErrorType.parsing,
        severity: ErrorSeverity.medium,
        userMessage: 'تعذر قراءة البيانات القادمة من السيرفر.',
        developerMessage: rawMessage,
      );
    }

    if (_looksLikeMapError(moduleHint, normalized)) {
      return ErrorMappingResult(
        code: ErrorCodes.mapFailure,
        type: ErrorType.map,
        severity: ErrorSeverity.medium,
        userMessage: 'تعذر تحميل الخريطة أو الموقع الحالي.',
        developerMessage: rawMessage,
      );
    }

    if (_looksLikeStorageError(moduleHint, normalized)) {
      return ErrorMappingResult(
        code: ErrorCodes.storageFailure,
        type: ErrorType.storage,
        severity: ErrorSeverity.medium,
        userMessage: 'تعذر حفظ البيانات محليًا. حاول مرة أخرى.',
        developerMessage: rawMessage,
      );
    }

    if (_looksLikeValidationByModule(moduleHint)) {
      return ErrorMappingResult(
        code: ErrorCodes.validationInvalidInput,
        type: ErrorType.validation,
        severity: ErrorSeverity.low,
        userMessage: 'البيانات المدخلة تحتاج مراجعة.',
        developerMessage: rawMessage,
      );
    }

    return ErrorMappingResult(
      code: ErrorCodes.unknownFailure,
      type: ErrorType.unknown,
      severity: ErrorSeverity.high,
      userMessage: 'حدث خطأ غير متوقع. حاول مرة أخرى.',
      developerMessage: rawMessage,
    );
  }

  static bool _isDuplicateKey(String? code, String message) {
    return code == '23505' ||
        message.contains('duplicate key') ||
        message.contains('already exists') ||
        message.contains('unique constraint');
  }

  static bool _isUnauthorizedCode(String? code) {
    final normalizedCode = (code ?? '').trim().toUpperCase();
    return normalizedCode == '401' ||
        normalizedCode == '403' ||
        normalizedCode == 'PGRST301' ||
        normalizedCode == 'PGRST303';
  }

  static bool _isPermissionDenied(String? code, String message) {
    return code == '42501' ||
        message.contains('permission denied') ||
        message.contains('not authorized') ||
        message.contains('forbidden');
  }

  static bool _looksLikeValidationError(String? code, String message) {
    final normalizedCode = (code ?? '').trim();
    return normalizedCode.startsWith('22') ||
        message.contains('invalid input') ||
        message.contains('validation') ||
        message.contains('failed to parse');
  }

  static bool _looksLikeNetworkError(String message) {
    return message.contains('socketexception') ||
        message.contains('failed host lookup') ||
        message.contains('network is unreachable') ||
        message.contains('connection refused') ||
        message.contains('connection reset by peer') ||
        message.contains('xmlhttprequest error') ||
        message.contains('clientexception') ||
        message.contains('network request failed') ||
        message.contains('no address associated with hostname');
  }

  static bool _looksLikeTimeout(String message) {
    return message.contains('timeoutexception') ||
        message.contains('timed out') ||
        message.contains('timeout');
  }

  static bool _looksLikeParsingError(String message) {
    return message.contains('formatexception') ||
        message.contains('syntaxerror') ||
        message.contains('typeerror') ||
        message.contains('json') && message.contains('unexpected');
  }

  static bool _looksLikeRealtimeError(String moduleHint, String message) {
    return moduleHint.contains('realtime') ||
        moduleHint.contains('websocket') ||
        moduleHint.contains('channel') ||
        message.contains('realtime') ||
        message.contains('websocket') ||
        message.contains('channel error') ||
        message.contains('rejoin') ||
        message.contains('subscription');
  }

  static bool _looksLikeNotificationError(String moduleHint, String message) {
    return moduleHint.contains('notification') ||
        moduleHint.contains('fcm') ||
        message.contains('notification') ||
        message.contains('firebase messaging') ||
        message.contains('fcm');
  }

  static bool _looksLikeMapError(String moduleHint, String message) {
    return moduleHint.contains('mapbox') ||
        moduleHint.contains('map') ||
        moduleHint.contains('location') ||
        message.contains('mapbox') ||
        message.contains('location permission');
  }

  static bool _looksLikeStorageError(String moduleHint, String message) {
    return moduleHint.contains('storage') ||
        moduleHint.contains('shared_preferences') ||
        message.contains('sharedpreferences') ||
        message.contains('storageexception');
  }

  static bool _looksLikeValidationByModule(String moduleHint) {
    return moduleHint.contains('validation') || moduleHint.contains('form');
  }

  static bool _isSessionExpiredMessage(String message) {
    return message.contains('jwt expired') ||
        message.contains('token expired') ||
        message.contains('token has expired') ||
        message.contains('session expired') ||
        message.contains('refresh token') ||
        message.contains('invalid jwt');
  }

  static String _normalizeWhitespace(String value) {
    return value.replaceAll(RegExp(r'\s+'), ' ').trim();
  }
}
