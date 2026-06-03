import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_error.dart';
import 'error_logger.dart';
import 'error_mapper.dart';
import 'error_reporter.dart';
import 'error_type.dart';
import 'error_ui.dart';

class ErrorMetricsSnapshot {
  const ErrorMetricsSnapshot({
    required this.totalErrors,
    required this.criticalErrors,
    required this.networkFailures,
    required this.realtimeFailures,
    required this.topErrors,
    required this.topScreens,
  });

  final int totalErrors;
  final int criticalErrors;
  final int networkFailures;
  final int realtimeFailures;
  final List<MapEntry<String, int>> topErrors;
  final List<MapEntry<String, int>> topScreens;

  double get crashRate {
    if (totalErrors == 0) {
      return 0;
    }
    return criticalErrors / totalErrors;
  }
}

class ErrorService {
  ErrorService._();

  static final ErrorService instance = ErrorService._();

  final ErrorReporter _reporter = ErrorReporter();
  final StreamController<AppError> _streamController =
      StreamController<AppError>.broadcast();

  final Map<String, int> _errorCountByCode = <String, int>{};
  final Map<String, int> _errorCountByScreen = <String, int>{};

  bool _initialized = false;
  String _appName = 'app';
  String _appVersion = 'unknown';
  int _totalErrors = 0;
  int _criticalErrors = 0;
  int _networkFailures = 0;
  int _realtimeFailures = 0;

  Stream<AppError> get stream => _streamController.stream;
  String get appName => _appName;

  Future<void> initialize({
    String appName = 'customer_app',
  }) async {
    if (_initialized) {
      return;
    }
    _appName = appName;
    _appVersion = await _resolveAppVersion();
    await _reporter.initialize();
    _initialized = true;
    unawaited(_reporter.flushQueue());
  }

  Future<void> dispose() async {
    await _reporter.dispose();
    await _streamController.close();
    _initialized = false;
  }

  Future<AppError> capture({
    required Object error,
    StackTrace? stackTrace,
    required String module,
    String? screen,
    String? action,
    String? userId,
    String? restaurantId,
    String? driverId,
    bool showUserMessage = false,
    bool includeCodeInSnack = false,
  }) async {
    try {
      if (!_initialized) {
        await initialize();
      }

      final mapping = ErrorMapper.map(
        error: error,
        module: module,
        action: action,
      );

      final resolvedUserId = userId ?? _currentUserId;
      final resolvedRestaurantId = restaurantId ?? _metadata('restaurant_id');
      final resolvedDriverId = driverId ?? _metadata('driver_id');
      final internetStatus = await _reporter.resolveInternetStatus();
      final createdAt = DateTime.now().toUtc();
      final effectiveStack = stackTrace ?? StackTrace.current;
      final appError = AppError(
        code: mapping.code,
        type: mapping.type,
        severity: mapping.severity,
        message: _redactSensitive(mapping.developerMessage),
        userMessage: mapping.userMessage,
        rawError: _redactSensitive(error.toString()),
        stackTrace: effectiveStack,
        screen: screen,
        action: action,
        module: module,
        appName: _appName,
        userId: resolvedUserId,
        restaurantId: resolvedRestaurantId,
        driverId: resolvedDriverId,
        deviceInfo: _deviceInfo(),
        osInfo: _osInfo(),
        appVersion: _appVersion,
        internetStatus: internetStatus,
        createdAt: createdAt,
        fingerprint: _fingerprint(
          type: mapping.type,
          stack: effectiveStack,
          module: module,
          action: action,
        ),
      );

      _track(appError);
      ErrorLogFormatter.log(appError);
      unawaited(_reporter.report(appError));
      _streamController.add(appError);

      if (showUserMessage) {
        ErrorUi.showSnackBar(
          message: appError.userMessage,
          code: includeCodeInSnack ? appError.code : null,
        );
      }

      return appError;
    } catch (captureError, captureStack) {
      debugPrint(
        '[CRITICAL][ERROR][${DateTime.now().toUtc().toIso8601String()}] '
        'ErrorService.capture failed: $captureError\n$captureStack',
      );
      final fallback = AppError(
        code: 'ERR-UNK-001',
        type: ErrorType.unknown,
        severity: ErrorSeverity.critical,
        message: 'Error service failed to process an exception: $captureError',
        userMessage: 'حدث خطأ غير متوقع. حاول مرة أخرى.',
        rawError: error.toString(),
        stackTrace: stackTrace ?? StackTrace.current,
        screen: screen,
        action: action,
        module: module,
        appName: _appName,
        userId: userId ?? _currentUserId,
        restaurantId: restaurantId,
        driverId: driverId,
        deviceInfo: _deviceInfo(),
        osInfo: _osInfo(),
        appVersion: _appVersion,
        internetStatus: 'unknown',
        createdAt: DateTime.now().toUtc(),
        fingerprint: sha256
            .convert(utf8.encode('unknown|$module|${action ?? '-'}'))
            .toString(),
      );
      if (showUserMessage) {
        ErrorUi.showSnackBar(
          message: fallback.userMessage,
          code: includeCodeInSnack ? fallback.code : null,
        );
      }
      return fallback;
    }
  }

  Future<T> guard<T>({
    required Future<T> Function() run,
    required String module,
    String? screen,
    String? action,
    T Function(AppError error)? fallback,
    bool showUserMessage = false,
  }) async {
    try {
      return await run();
    } catch (error, stack) {
      final appError = await capture(
        error: error,
        stackTrace: stack,
        module: module,
        screen: screen,
        action: action,
        showUserMessage: showUserMessage,
      );
      if (fallback != null) {
        return fallback(appError);
      }
      rethrow;
    }
  }

  ErrorMetricsSnapshot metrics() {
    final topErrors = _topEntries(_errorCountByCode);
    final topScreens = _topEntries(_errorCountByScreen);
    return ErrorMetricsSnapshot(
      totalErrors: _totalErrors,
      criticalErrors: _criticalErrors,
      networkFailures: _networkFailures,
      realtimeFailures: _realtimeFailures,
      topErrors: topErrors,
      topScreens: topScreens,
    );
  }

  Future<List<Map<String, dynamic>>> topErrorsFromSupabase({
    int limit = 10,
  }) async {
    final client = _clientOrNull;
    if (client == null) {
      return const <Map<String, dynamic>>[];
    }

    try {
      final response = await client
          .from('system_errors')
          .select('error_code, occurrences')
          .limit(500);
      final aggregate = <String, int>{};
      for (final row in (response as List<dynamic>).whereType<Map>()) {
        final key = row['error_code']?.toString().trim();
        if (key == null || key.isEmpty) {
          continue;
        }
        final occurrences = _toInt(row['occurrences']) ?? 1;
        aggregate.update(key, (value) => value + occurrences,
            ifAbsent: () => occurrences);
      }
      final entries = aggregate.entries.toList(growable: false)
        ..sort((a, b) => b.value.compareTo(a.value));
      return entries
          .take(limit)
          .map((entry) => <String, dynamic>{
                'error_code': entry.key,
                'occurrences': entry.value,
              })
          .toList(growable: false);
    } catch (_) {
      return const <Map<String, dynamic>>[];
    }
  }

  Future<List<Map<String, dynamic>>> topScreensFromSupabase({
    int limit = 10,
  }) async {
    final client = _clientOrNull;
    if (client == null) {
      return const <Map<String, dynamic>>[];
    }

    try {
      final response = await client
          .from('system_errors')
          .select('screen, occurrences')
          .limit(500);
      final aggregate = <String, int>{};
      for (final row in (response as List<dynamic>).whereType<Map>()) {
        final key = row['screen']?.toString().trim();
        if (key == null || key.isEmpty) {
          continue;
        }
        final occurrences = _toInt(row['occurrences']) ?? 1;
        aggregate.update(key, (value) => value + occurrences,
            ifAbsent: () => occurrences);
      }
      final entries = aggregate.entries.toList(growable: false)
        ..sort((a, b) => b.value.compareTo(a.value));
      return entries
          .take(limit)
          .map((entry) => <String, dynamic>{
                'screen': entry.key,
                'occurrences': entry.value,
              })
          .toList(growable: false);
    } catch (_) {
      return const <Map<String, dynamic>>[];
    }
  }

  void _track(AppError error) {
    _totalErrors += 1;
    if (error.severity == ErrorSeverity.critical) {
      _criticalErrors += 1;
    }
    if (error.type == ErrorType.network || error.type == ErrorType.timeout) {
      _networkFailures += 1;
    }
    if (error.type == ErrorType.realtime) {
      _realtimeFailures += 1;
    }

    _errorCountByCode.update(error.code, (value) => value + 1,
        ifAbsent: () => 1);
    final screenKey = (error.screen == null || error.screen!.isEmpty)
        ? 'unknown'
        : error.screen!;
    _errorCountByScreen.update(
      screenKey,
      (value) => value + 1,
      ifAbsent: () => 1,
    );
  }

  String _fingerprint({
    required ErrorType type,
    required StackTrace? stack,
    required String module,
    required String? action,
  }) {
    final input = [
      type.name,
      module.trim().toLowerCase(),
      (action ?? '').trim().toLowerCase(),
      _normalizeStack(stack),
    ].join('|');
    return sha256.convert(utf8.encode(input)).toString();
  }

  String _normalizeStack(StackTrace? stack) {
    if (stack == null) {
      return '-';
    }
    final lines = stack
        .toString()
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .take(6)
        .toList(growable: false);
    return lines.join('|').toLowerCase();
  }

  String _deviceInfo() {
    final locale = PlatformDispatcher.instance.locale.toLanguageTag();
    final platform = defaultTargetPlatform.name;
    final realtime = _realtimeState();
    return 'platform=$platform; locale=$locale; web=$kIsWeb; realtime=$realtime';
  }

  String _osInfo() {
    final platform = defaultTargetPlatform.name;
    return kIsWeb ? 'web($platform)' : platform;
  }

  String _realtimeState() {
    final client = _clientOrNull;
    if (client == null) {
      return 'unavailable';
    }
    try {
      final dynamic realtime = client.realtime;
      final dynamic state = realtime.connectionState;
      if (state != null) {
        return state.toString();
      }
    } catch (_) {}

    try {
      final dynamic realtime = client.realtime;
      final dynamic isConnected = realtime.isConnected();
      if (isConnected is bool) {
        return isConnected ? 'connected' : 'disconnected';
      }
    } catch (_) {}

    return 'unknown';
  }

  String? _metadata(String key) {
    final user = _clientOrNull?.auth.currentUser;
    final value = user?.userMetadata?[key];
    final text = value?.toString().trim();
    if (text == null || text.isEmpty) {
      return null;
    }
    return text;
  }

  String? get _currentUserId => _clientOrNull?.auth.currentUser?.id;

  SupabaseClient? get _clientOrNull {
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }

  Future<String> _resolveAppVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final version = info.version.trim();
      final build = info.buildNumber.trim();
      if (version.isEmpty && build.isEmpty) {
        return 'unknown';
      }
      if (build.isEmpty) {
        return version;
      }
      return '$version+$build';
    } catch (_) {
      return 'unknown';
    }
  }

  List<MapEntry<String, int>> _topEntries(Map<String, int> source) {
    final entries = source.entries.toList(growable: false)
      ..sort((a, b) => b.value.compareTo(a.value));
    return entries.take(10).toList(growable: false);
  }

  String _redactSensitive(String input) {
    var output = input;

    output = output.replaceAllMapped(
      RegExp(r'(access_token=)([^&\s]+)', caseSensitive: false),
      (m) => '${m.group(1)}<redacted>',
    );
    output = output.replaceAllMapped(
      RegExp(r'eyJ[a-zA-Z0-9_-]*\.[a-zA-Z0-9_-]+\.[a-zA-Z0-9_-]+'),
      (_) => '<redacted.jwt>',
    );
    output = output.replaceAllMapped(
      RegExp(r'pk\.[a-zA-Z0-9_-]+\.[a-zA-Z0-9_-]+'),
      (_) => '<redacted.mapbox>',
    );

    return output;
  }

  int? _toInt(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse(value?.toString() ?? '');
  }
}
