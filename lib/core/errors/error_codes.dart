import 'error_type.dart';

class ErrorCodes {
  ErrorCodes._();

  static const String networkNoInternet = 'ERR-NET-001';
  static const String networkTimeout = 'ERR-NET-002';
  static const String networkServerUnavailable = 'ERR-NET-003';
  static const String authSessionExpired = 'ERR-AUTH-001';
  static const String authUnauthorized = 'ERR-AUTH-002';
  static const String validationInvalidInput = 'ERR-VAL-001';
  static const String databaseFailure = 'ERR-DB-001';
  static const String databaseDuplicateKey = 'ERR-DB-002';
  static const String permissionDenied = 'ERR-PERM-001';
  static const String paymentFailure = 'ERR-PAY-001';
  static const String notificationFailure = 'ERR-NOTIF-001';
  static const String mapFailure = 'ERR-MAP-001';
  static const String storageFailure = 'ERR-STO-001';
  static const String realtimeFailure = 'ERR-REALTIME-001';
  static const String parsingFailure = 'ERR-PARSE-001';
  static const String unknownFailure = 'ERR-UNK-001';

  static String byType(ErrorType type) {
    switch (type) {
      case ErrorType.network:
        return networkNoInternet;
      case ErrorType.auth:
        return authUnauthorized;
      case ErrorType.validation:
        return validationInvalidInput;
      case ErrorType.database:
        return databaseFailure;
      case ErrorType.permission:
        return permissionDenied;
      case ErrorType.payment:
        return paymentFailure;
      case ErrorType.notification:
        return notificationFailure;
      case ErrorType.map:
        return mapFailure;
      case ErrorType.storage:
        return storageFailure;
      case ErrorType.realtime:
        return realtimeFailure;
      case ErrorType.timeout:
        return networkTimeout;
      case ErrorType.parsing:
        return parsingFailure;
      case ErrorType.unknown:
        return unknownFailure;
    }
  }
}
