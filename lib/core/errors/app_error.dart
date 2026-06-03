import 'dart:convert';

import 'error_type.dart';

class AppError implements Exception {
  AppError({
    required this.code,
    required this.type,
    required this.severity,
    required this.message,
    required this.userMessage,
    required this.rawError,
    required this.stackTrace,
    required this.screen,
    required this.action,
    required this.module,
    required this.appName,
    required this.userId,
    required this.restaurantId,
    required this.driverId,
    required this.deviceInfo,
    required this.osInfo,
    required this.appVersion,
    required this.internetStatus,
    required this.createdAt,
    required this.fingerprint,
    this.occurrences = 1,
  });

  final String code;
  final ErrorType type;
  final ErrorSeverity severity;
  final String message;
  final String userMessage;
  final Object? rawError;
  final StackTrace? stackTrace;
  final String? screen;
  final String? action;
  final String module;
  final String appName;
  final String? userId;
  final String? restaurantId;
  final String? driverId;
  final String deviceInfo;
  final String osInfo;
  final String appVersion;
  final String internetStatus;
  final DateTime createdAt;
  final String fingerprint;
  final int occurrences;

  String get rawErrorText => _safeText(rawError);
  String? get stackTraceText => stackTrace?.toString();

  AppError copyWith({
    String? code,
    ErrorType? type,
    ErrorSeverity? severity,
    String? message,
    String? userMessage,
    Object? rawError,
    StackTrace? stackTrace,
    String? screen,
    String? action,
    String? module,
    String? appName,
    String? userId,
    String? restaurantId,
    String? driverId,
    String? deviceInfo,
    String? osInfo,
    String? appVersion,
    String? internetStatus,
    DateTime? createdAt,
    String? fingerprint,
    int? occurrences,
  }) {
    return AppError(
      code: code ?? this.code,
      type: type ?? this.type,
      severity: severity ?? this.severity,
      message: message ?? this.message,
      userMessage: userMessage ?? this.userMessage,
      rawError: rawError ?? this.rawError,
      stackTrace: stackTrace ?? this.stackTrace,
      screen: screen ?? this.screen,
      action: action ?? this.action,
      module: module ?? this.module,
      appName: appName ?? this.appName,
      userId: userId ?? this.userId,
      restaurantId: restaurantId ?? this.restaurantId,
      driverId: driverId ?? this.driverId,
      deviceInfo: deviceInfo ?? this.deviceInfo,
      osInfo: osInfo ?? this.osInfo,
      appVersion: appVersion ?? this.appVersion,
      internetStatus: internetStatus ?? this.internetStatus,
      createdAt: createdAt ?? this.createdAt,
      fingerprint: fingerprint ?? this.fingerprint,
      occurrences: occurrences ?? this.occurrences,
    );
  }

  Map<String, dynamic> toSupabasePayload() {
    return {
      'app_name': appName,
      'module': module,
      'screen': screen,
      'action': action,
      'error_type': type.name,
      'severity': severity.name,
      'error_code': code,
      'user_message': userMessage,
      'developer_message': message,
      'raw_error': rawErrorText,
      'stacktrace': stackTraceText,
      'user_id': userId,
      'restaurant_id': restaurantId,
      'driver_id': driverId,
      'device': deviceInfo,
      'os': osInfo,
      'app_version': appVersion,
      'internet_status': internetStatus,
      'fingerprint': fingerprint,
      'occurrences': occurrences,
      'status': 'open',
      'is_resolved': false,
      'created_at': createdAt.toUtc().toIso8601String(),
      // Backward compatibility with existing schema.
      'error_message': message,
      'stack_trace': stackTraceText,
    };
  }

  Map<String, dynamic> toLocalJson() {
    return {
      'code': code,
      'type': type.name,
      'severity': severity.name,
      'message': message,
      'userMessage': userMessage,
      'rawError': rawErrorText,
      'stackTrace': stackTraceText,
      'screen': screen,
      'action': action,
      'module': module,
      'appName': appName,
      'userId': userId,
      'restaurantId': restaurantId,
      'driverId': driverId,
      'deviceInfo': deviceInfo,
      'osInfo': osInfo,
      'appVersion': appVersion,
      'internetStatus': internetStatus,
      'createdAt': createdAt.toUtc().toIso8601String(),
      'fingerprint': fingerprint,
      'occurrences': occurrences,
    };
  }

  static AppError fromLocalJson(Map<String, dynamic> json) {
    final createdAtRaw = json['createdAt']?.toString();
    final createdAt = createdAtRaw == null
        ? DateTime.now().toUtc()
        : DateTime.tryParse(createdAtRaw)?.toUtc() ?? DateTime.now().toUtc();

    return AppError(
      code: json['code']?.toString() ?? '',
      type: parseErrorType(json['type']?.toString()),
      severity: parseErrorSeverity(json['severity']?.toString()),
      message: json['message']?.toString() ?? '',
      userMessage: json['userMessage']?.toString() ?? '',
      rawError: json['rawError']?.toString(),
      stackTrace: _stackTraceFromString(json['stackTrace']?.toString()),
      screen: json['screen']?.toString(),
      action: json['action']?.toString(),
      module: json['module']?.toString() ?? 'unknown',
      appName: json['appName']?.toString() ?? 'app',
      userId: json['userId']?.toString(),
      restaurantId: json['restaurantId']?.toString(),
      driverId: json['driverId']?.toString(),
      deviceInfo: json['deviceInfo']?.toString() ?? 'unknown',
      osInfo: json['osInfo']?.toString() ?? 'unknown',
      appVersion: json['appVersion']?.toString() ?? 'unknown',
      internetStatus: json['internetStatus']?.toString() ?? 'unknown',
      createdAt: createdAt,
      fingerprint: json['fingerprint']?.toString() ?? '',
      occurrences: _toInt(json['occurrences']) ?? 1,
    );
  }

  String toJsonString() => jsonEncode(toLocalJson());

  static AppError? fromJsonString(String source) {
    try {
      final decoded = jsonDecode(source);
      if (decoded is! Map<String, dynamic>) {
        return null;
      }
      return fromLocalJson(decoded);
    } catch (_) {
      return null;
    }
  }

  static int? _toInt(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse(value?.toString() ?? '');
  }

  static StackTrace? _stackTraceFromString(String? value) {
    if (value == null || value.trim().isEmpty) {
      return null;
    }
    return StackTrace.fromString(value);
  }

  static String _safeText(Object? value) {
    if (value == null) {
      return '';
    }
    final text = value.toString();
    if (text.isEmpty) {
      return '';
    }
    return text;
  }

  @override
  String toString() {
    return 'AppError(code: $code, type: ${type.name}, '
        'severity: ${severity.name}, module: $module, message: $message)';
  }
}
