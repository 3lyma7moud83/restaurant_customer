import 'package:flutter/foundation.dart';

class StabilityLogger {
  StabilityLogger._();

  static void checkout(String message) => _log('CHECKOUT', message);
  static void payment(String message) => _log('PAYMENT', message);
  static void cart(String message) => _log('CART', message);
  static void session(String message) => _log('SESSION', message);
  static void offlineQueue(String message) => _log('OFFLINE_QUEUE', message);
  static void notification(String message) => _log('NOTIFICATION', message);
  static void deliveryConfirmation(String message) =>
      _log('DELIVERY_CONFIRMATION', message);
  static void abuse(String message) => _log('ABUSE', message);
  static void reconciliation(String message) => _log('RECONCILIATION', message);
  static void realtime(String message) => _log('REALTIME', message);
  static void analytics(String message) => _log('ANALYTICS', message);
  static void security(String message) => _securityLog('SECURITY', message);
  static void rpcReplay(String message) => _securityLog('RPC_REPLAY', message);
  static void sessionTheft(String message) =>
      _securityLog('SESSION_THEFT', message);
  static void authRevalidation(String message) =>
      _securityLog('AUTH_REVALIDATION', message);
  static void escalation(String message) => _securityLog('ESCALATION', message);
  static void immutableAudit(String message) =>
      _securityLog('IMMUTABLE_AUDIT', message);
  static void dlqPoison(String message) => _securityLog('DLQ_POISON', message);
  static void revocation(String message) => _securityLog('REVOCATION', message);

  static void _log(String tag, String message) {
    final timestamp = DateTime.now().toUtc().toIso8601String();
    debugPrint('[$tag][$timestamp] $message');
  }

  static void _securityLog(String tag, String message) {
    final timestamp = DateTime.now().toUtc().toIso8601String();
    debugPrint('[SECURITY][$tag][$timestamp] $message');
  }
}
