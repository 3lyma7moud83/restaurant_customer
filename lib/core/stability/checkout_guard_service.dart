import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/error_logger.dart';
import 'stability_logger.dart';
import 'stability_metrics_service.dart';

class CheckoutGuardDecision {
  const CheckoutGuardDecision({
    required this.allowed,
    required this.message,
    this.orderRequestToken,
    this.checkoutSessionId,
    this.safeMode = false,
  });

  final bool allowed;
  final String message;
  final String? orderRequestToken;
  final String? checkoutSessionId;
  final bool safeMode;
}

class CheckoutGuardService {
  CheckoutGuardService._();

  static final CheckoutGuardService instance = CheckoutGuardService._();

  static const String _storageKey = 'checkout_guard_state.v1';
  static const Duration _rapidTapWindow = Duration(milliseconds: 900);
  static const Duration _lockDuration = Duration(seconds: 20);
  static const Duration _attemptWindow = Duration(minutes: 2);
  static const Duration _safeModeDuration = Duration(minutes: 3);

  SharedPreferences? _prefs;
  DateTime? _lastAttemptAt;
  DateTime? _lockUntil;
  DateTime? _safeModeUntil;
  String? _activeOrderRequestToken;
  String? _activeCheckoutSessionId;
  final List<DateTime> _attempts = <DateTime>[];
  bool _initialized = false;

  bool get isSafeMode {
    final until = _safeModeUntil;
    if (until == null) {
      return false;
    }
    return DateTime.now().isBefore(until);
  }

  Future<void> initialize() async {
    if (_initialized) {
      return;
    }
    _initialized = true;
    _prefs = await SharedPreferences.getInstance();
    await _restore();
  }

  Future<CheckoutGuardDecision> start({
    required String userId,
    required String restaurantId,
    required double totalAmount,
  }) async {
    await initialize();
    await StabilityMetricsService.instance.initialize();

    final now = DateTime.now();
    _attempts.removeWhere((value) => now.difference(value) > _attemptWindow);

    if (_lastAttemptAt != null &&
        now.difference(_lastAttemptAt!) < _rapidTapWindow) {
      StabilityMetricsService.instance.increment(
        'duplicate_order_attempts',
        module: 'checkout_guard',
      );
      StabilityLogger.checkout(
        'Rapid checkout tap blocked for user=$userId restaurant=$restaurantId.',
      );
      return const CheckoutGuardDecision(
        allowed: false,
        message: 'تم تجاهل الضغطات المتكررة. انتظر لحظة ثم أعد المحاولة.',
      );
    }

    if (_lockUntil != null && now.isBefore(_lockUntil!)) {
      StabilityMetricsService.instance.increment(
        'duplicate_order_attempts',
        module: 'checkout_guard',
      );
      return const CheckoutGuardDecision(
        allowed: false,
        message: 'يوجد طلب قيد المعالجة الآن. انتظر قليلًا.',
      );
    }

    if (_attempts.length >= 6) {
      await _trackAbuse(
        userId: userId,
        abuseKey: 'rapid_checkout',
        score: _attempts.length + 1,
        metadata: {
          'restaurant_id': restaurantId,
          'total_amount': totalAmount,
          'window_seconds': _attemptWindow.inSeconds,
        },
      );
      StabilityMetricsService.instance.increment(
        'abuse_detections',
        module: 'checkout_guard',
      );
      return const CheckoutGuardDecision(
        allowed: false,
        message: 'عدد محاولات الدفع كبير جدًا. حاول مرة أخرى بعد دقيقة.',
      );
    }

    _attempts.add(now);
    _lastAttemptAt = now;
    _lockUntil = now.add(_lockDuration);
    _activeCheckoutSessionId = _generateToken(prefix: 'ck');
    _activeOrderRequestToken = _generateToken(prefix: 'ord');
    await _persist();

    final safeMode = isSafeMode;
    final message = safeMode
        ? 'وضع الدفع الآمن مفعل مؤقتًا. سيتم تنفيذ الطلب بحماية إضافية.'
        : 'Checkout started';

    StabilityLogger.checkout(
      'Started checkout session=$_activeCheckoutSessionId '
      'requestToken=$_activeOrderRequestToken safeMode=$safeMode',
    );

    return CheckoutGuardDecision(
      allowed: true,
      message: message,
      orderRequestToken: _activeOrderRequestToken,
      checkoutSessionId: _activeCheckoutSessionId,
      safeMode: safeMode,
    );
  }

  Future<void> completeSuccess({String? orderId}) async {
    await initialize();
    StabilityLogger.checkout(
      'Checkout completed successfully orderId=${orderId ?? '-'} '
      'requestToken=${_activeOrderRequestToken ?? '-'}',
    );
    _lockUntil = null;
    _activeCheckoutSessionId = null;
    _activeOrderRequestToken = null;
    await _persist();
  }

  Future<void> completeFailure({
    required String reason,
    bool enableSafeMode = false,
  }) async {
    await initialize();
    StabilityLogger.checkout('Checkout failed reason=$reason');
    StabilityMetricsService.instance.increment(
      'checkout_failures',
      module: 'checkout_guard',
      payload: {'reason': reason},
    );
    _lockUntil = null;

    if (enableSafeMode) {
      await activateSafeMode(reason: reason);
    }

    await _persist();
  }

  Future<void> markQueuedOffline() async {
    await initialize();
    _lockUntil = null;
    await _persist();
    StabilityLogger.offlineQueue(
      'Checkout moved to offline queue token=${_activeOrderRequestToken ?? '-'}',
    );
  }

  String? get activeOrderRequestToken => _activeOrderRequestToken;
  String? get activeCheckoutSessionId => _activeCheckoutSessionId;

  Future<void> clearStalePendingState() async {
    await initialize();
    final lockUntil = _lockUntil;
    if (lockUntil != null && DateTime.now().isAfter(lockUntil)) {
      _lockUntil = null;
      await _persist();
    }
  }

  Future<void> activateSafeMode({
    required String reason,
    Duration? duration,
  }) async {
    await initialize();
    final safeDuration = duration ?? _safeModeDuration;
    final until = DateTime.now().add(safeDuration);
    final existingUntil = _safeModeUntil;
    if (existingUntil == null || until.isAfter(existingUntil)) {
      _safeModeUntil = until;
    }
    _lockUntil = null;
    await _persist();
    StabilityLogger.checkout(
      'Safe checkout mode enabled reason=$reason for ${safeDuration.inSeconds}s',
    );
    StabilityMetricsService.instance.increment(
      'safe_checkout_mode_activations',
      module: 'checkout_guard',
      payload: {'reason': reason},
    );
  }

  Future<void> _trackAbuse({
    required String userId,
    required String abuseKey,
    required int score,
    required Map<String, dynamic> metadata,
  }) async {
    final client = _clientOrNull;
    if (client == null) {
      return;
    }
    try {
      await client.from('abuse_tracking').insert({
        'user_id': userId,
        'module': 'checkout',
        'abuse_key': abuseKey,
        'score': score,
        'metadata': metadata,
      });
      StabilityLogger.abuse(
        'Abuse tracked user=$userId key=$abuseKey score=$score',
      );
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'checkout_guard_service.track_abuse',
        error: error,
        stack: stack,
      );
    }
  }

  Future<void> _restore() async {
    final raw = _prefs?.getString(_storageKey);
    if (raw == null || raw.isEmpty) {
      return;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return;
      }

      _lastAttemptAt = _parseDate(decoded['last_attempt_at']?.toString());
      _lockUntil = _parseDate(decoded['lock_until']?.toString());
      _safeModeUntil = _parseDate(decoded['safe_mode_until']?.toString());
      _activeOrderRequestToken = _toNullableText(decoded['order_request_token']);
      _activeCheckoutSessionId =
          _toNullableText(decoded['checkout_session_id']);

      final attempts = decoded['attempts'];
      if (attempts is List) {
        _attempts
          ..clear()
          ..addAll(
            attempts
                .map((item) => _parseDate(item?.toString()))
                .whereType<DateTime>(),
          );
      }
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'checkout_guard_service.restore',
        error: error,
        stack: stack,
      );
    }
  }

  Future<void> _persist() async {
    final prefs = _prefs;
    if (prefs == null) {
      return;
    }
    final payload = jsonEncode({
      'last_attempt_at': _lastAttemptAt?.toUtc().toIso8601String(),
      'lock_until': _lockUntil?.toUtc().toIso8601String(),
      'safe_mode_until': _safeModeUntil?.toUtc().toIso8601String(),
      'order_request_token': _activeOrderRequestToken,
      'checkout_session_id': _activeCheckoutSessionId,
      'attempts':
          _attempts.map((item) => item.toUtc().toIso8601String()).toList(),
    });
    await prefs.setString(_storageKey, payload);
  }

  DateTime? _parseDate(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }
    return DateTime.tryParse(raw)?.toLocal();
  }

  String _generateToken({required String prefix}) {
    final random = Random.secure();
    final seed = StringBuffer(prefix)
      ..write('|')
      ..write(DateTime.now().toUtc().microsecondsSinceEpoch)
      ..write('|')
      ..write(random.nextInt(1 << 31))
      ..write('|')
      ..write(_clientOrNull?.auth.currentUser?.id ?? '-');
    final digest = sha256.convert(utf8.encode(seed.toString())).toString();
    return '$prefix-${digest.substring(0, 24)}';
  }

  String? _toNullableText(Object? value) {
    final text = value?.toString().trim();
    if (text == null || text.isEmpty) {
      return null;
    }
    return text;
  }

  SupabaseClient? get _clientOrNull {
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }
}
