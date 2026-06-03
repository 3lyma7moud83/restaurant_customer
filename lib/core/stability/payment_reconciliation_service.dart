import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/error_logger.dart';
import 'stability_logger.dart';
import 'stability_metrics_service.dart';

class PaymentSnapshot {
  const PaymentSnapshot({
    required this.paymentReferenceId,
    required this.userId,
    required this.orderRequestToken,
    required this.checkoutSessionId,
    required this.paymentMethod,
    required this.amount,
    required this.status,
    required this.reconciliationStatus,
    required this.verificationAttempts,
    required this.createdAt,
    required this.updatedAt,
    this.orderId,
  });

  final String paymentReferenceId;
  final String userId;
  final String orderRequestToken;
  final String checkoutSessionId;
  final String paymentMethod;
  final double amount;
  final String status;
  final String reconciliationStatus;
  final int verificationAttempts;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? orderId;

  bool get isPending =>
      status == 'pending' ||
      status == 'queued' ||
      status == 'verifying' ||
      status == 'pending_review';

  PaymentSnapshot copyWith({
    String? paymentReferenceId,
    String? userId,
    String? orderRequestToken,
    String? checkoutSessionId,
    String? paymentMethod,
    double? amount,
    String? status,
    String? reconciliationStatus,
    int? verificationAttempts,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? orderId,
  }) {
    return PaymentSnapshot(
      paymentReferenceId: paymentReferenceId ?? this.paymentReferenceId,
      userId: userId ?? this.userId,
      orderRequestToken: orderRequestToken ?? this.orderRequestToken,
      checkoutSessionId: checkoutSessionId ?? this.checkoutSessionId,
      paymentMethod: paymentMethod ?? this.paymentMethod,
      amount: amount ?? this.amount,
      status: status ?? this.status,
      reconciliationStatus: reconciliationStatus ?? this.reconciliationStatus,
      verificationAttempts: verificationAttempts ?? this.verificationAttempts,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      orderId: orderId ?? this.orderId,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'payment_reference_id': paymentReferenceId,
      'user_id': userId,
      'order_request_token': orderRequestToken,
      'checkout_session_id': checkoutSessionId,
      'payment_method': paymentMethod,
      'amount': amount,
      'status': status,
      'reconciliation_status': reconciliationStatus,
      'verification_attempts': verificationAttempts,
      'created_at': createdAt.toUtc().toIso8601String(),
      'updated_at': updatedAt.toUtc().toIso8601String(),
      'order_id': orderId,
    };
  }

  static PaymentSnapshot? fromJson(Map<String, dynamic> json) {
    final paymentReferenceId =
        json['payment_reference_id']?.toString().trim() ?? '';
    final userId = json['user_id']?.toString().trim() ?? '';
    final orderRequestToken =
        json['order_request_token']?.toString().trim() ?? '';
    final checkoutSessionId =
        json['checkout_session_id']?.toString().trim() ?? '';
    if (paymentReferenceId.isEmpty ||
        userId.isEmpty ||
        orderRequestToken.isEmpty ||
        checkoutSessionId.isEmpty) {
      return null;
    }

    final createdAt = DateTime.tryParse(
          json['created_at']?.toString() ?? '',
        ) ??
        DateTime.now().toUtc();
    final updatedAt = DateTime.tryParse(
          json['updated_at']?.toString() ?? '',
        ) ??
        DateTime.now().toUtc();

    return PaymentSnapshot(
      paymentReferenceId: paymentReferenceId,
      userId: userId,
      orderRequestToken: orderRequestToken,
      checkoutSessionId: checkoutSessionId,
      paymentMethod: json['payment_method']?.toString() ?? 'cash',
      amount: _toDouble(json['amount']) ?? 0,
      status: json['status']?.toString() ?? 'pending',
      reconciliationStatus:
          json['reconciliation_status']?.toString() ?? 'pending',
      verificationAttempts: _toInt(json['verification_attempts']) ?? 0,
      createdAt: createdAt.toUtc(),
      updatedAt: updatedAt.toUtc(),
      orderId: _toNullableText(json['order_id']),
    );
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

  static double? _toDouble(Object? value) {
    if (value is num) {
      return value.toDouble();
    }
    return double.tryParse(value?.toString() ?? '');
  }

  static String? _toNullableText(Object? value) {
    final text = value?.toString().trim();
    if (text == null || text.isEmpty) {
      return null;
    }
    return text;
  }
}

class PaymentReconciliationService {
  PaymentReconciliationService._();

  static final PaymentReconciliationService instance =
      PaymentReconciliationService._();

  static const String _storageKey = 'payment_reconciliation_snapshots.v1';
  static const Duration _stuckPendingThreshold = Duration(minutes: 20);
  static const Duration _manualReviewRetryCooldown = Duration(minutes: 2);
  static const int _maxVerificationAttempts = 8;

  final List<PaymentSnapshot> _snapshots = <PaymentSnapshot>[];
  final Connectivity _connectivity = Connectivity();
  SharedPreferences? _prefs;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  Timer? _reconciliationTimer;
  bool _initialized = false;
  bool _reconcileInFlight = false;

  Future<void> initialize() async {
    if (_initialized) {
      return;
    }
    _initialized = true;
    await StabilityMetricsService.instance.initialize();
    _prefs = await SharedPreferences.getInstance();
    await _restore();
    _connectivitySubscription = _connectivity.onConnectivityChanged.listen(
      (results) {
        if (results.contains(ConnectivityResult.none)) {
          return;
        }
        unawaited(reconcilePendingPayments(trigger: 'connectivity_restored'));
      },
      onError: (_) {},
    );
    _reconciliationTimer = Timer.periodic(
      const Duration(seconds: 45),
      (_) => unawaited(reconcilePendingPayments(trigger: 'timer')),
    );
    unawaited(reconcilePendingPayments(trigger: 'startup'));
  }

  Future<String> registerPendingPayment({
    required String userId,
    required String orderRequestToken,
    required String checkoutSessionId,
    required String paymentMethod,
    required double amount,
  }) async {
    await initialize();

    final paymentReferenceId =
        'pay-${DateTime.now().toUtc().microsecondsSinceEpoch}-$orderRequestToken';
    final now = DateTime.now().toUtc();
    final snapshot = PaymentSnapshot(
      paymentReferenceId: paymentReferenceId,
      userId: userId,
      orderRequestToken: orderRequestToken,
      checkoutSessionId: checkoutSessionId,
      paymentMethod: paymentMethod,
      amount: amount,
      status: 'pending',
      reconciliationStatus: 'pending',
      verificationAttempts: 0,
      createdAt: now,
      updatedAt: now,
    );

    _upsertSnapshot(snapshot);
    await _persist();
    StabilityLogger.payment(
      'Registered pending payment ref=$paymentReferenceId token=$orderRequestToken',
    );
    return paymentReferenceId;
  }

  Future<void> markOrderLinked({
    required String paymentReferenceId,
    required String orderId,
  }) async {
    await _mutateByReference(
      paymentReferenceId,
      (snapshot) => snapshot.copyWith(
        orderId: orderId,
        status: 'confirmed',
        reconciliationStatus: 'verified',
        updatedAt: DateTime.now().toUtc(),
      ),
      metricKey: 'payment_reconciliations',
      logMessage:
          'Payment linked ref=$paymentReferenceId orderId=$orderId status=confirmed',
    );
  }

  Future<void> markQueued({
    required String paymentReferenceId,
  }) async {
    await _mutateByReference(
      paymentReferenceId,
      (snapshot) => snapshot.copyWith(
        status: 'queued',
        reconciliationStatus: 'queued_offline',
        updatedAt: DateTime.now().toUtc(),
      ),
      metricKey: 'payment_queued_offline',
      logMessage: 'Payment queued for reconciliation ref=$paymentReferenceId',
    );
  }

  Future<void> markFailed({
    required String paymentReferenceId,
    required String reason,
  }) async {
    await _mutateByReference(
      paymentReferenceId,
      (snapshot) => snapshot.copyWith(
        status: 'failed',
        reconciliationStatus: reason,
        updatedAt: DateTime.now().toUtc(),
      ),
      metricKey: 'payment_failures',
      logMessage: 'Payment marked failed ref=$paymentReferenceId reason=$reason',
    );
  }

  Future<void> reconcilePendingPayments({
    required String trigger,
  }) async {
    if (_reconcileInFlight) {
      return;
    }
    if (_snapshots.isEmpty) {
      return;
    }

    final client = _clientOrNull;
    if (client == null) {
      return;
    }

    _reconcileInFlight = true;
    try {
      final pending = _snapshots.where((snapshot) => snapshot.isPending).toList();
      for (final snapshot in pending) {
        if (snapshot.status == 'pending_review' &&
            DateTime.now().toUtc().difference(snapshot.updatedAt) <
                _manualReviewRetryCooldown) {
          continue;
        }

        final nextAttempt = snapshot.verificationAttempts + 1;
        final now = DateTime.now().toUtc();
        var updated = snapshot.copyWith(
          verificationAttempts: nextAttempt,
          reconciliationStatus: 'verifying',
          updatedAt: now,
        );
        _upsertSnapshot(updated);

        final tokenRow = await _loadOrderRequestTokenRow(
          client: client,
          userId: snapshot.userId,
          orderRequestToken: snapshot.orderRequestToken,
        );
        final serverStatus = tokenRow?['status']?.toString();
        final serverOrderId = tokenRow?['order_id']?.toString();
        final normalizedServerStatus =
            serverStatus?.trim().toLowerCase() ?? 'unknown';

        if (normalizedServerStatus == 'failed' ||
            normalizedServerStatus == 'cancelled' ||
            normalizedServerStatus == 'rejected') {
          updated = updated.copyWith(
            status: 'failed',
            reconciliationStatus: 'server_reported_failure',
            updatedAt: DateTime.now().toUtc(),
          );
          _upsertSnapshot(updated);
          StabilityMetricsService.instance.increment(
            'payment_mismatches',
            module: 'payment_reconciliation',
            payload: {'reason': 'server_reported_failure', 'trigger': trigger},
          );
          await _recordReconciliationLog(
            client: client,
            snapshot: updated,
            serverStatus: serverStatus,
            mismatchReason: 'server_reported_failure',
          );
          continue;
        }

        if (serverOrderId != null && serverOrderId.trim().isNotEmpty) {
          final orderStatusRow = await _loadOrderStatusRow(
            client: client,
            orderId: serverOrderId.trim(),
          );
          final orderStatus =
              orderStatusRow?['status']?.toString().trim().toLowerCase();
          if (orderStatus == 'cancelled' ||
              orderStatus == 'rejected' ||
              orderStatus == 'failed') {
            updated = updated.copyWith(
              orderId: serverOrderId.trim(),
              status: 'pending_review',
              reconciliationStatus: 'order_state_mismatch',
              updatedAt: DateTime.now().toUtc(),
            );
            _upsertSnapshot(updated);
            StabilityMetricsService.instance.increment(
              'payment_mismatches',
              module: 'payment_reconciliation',
              payload: {'reason': 'order_state_mismatch', 'trigger': trigger},
            );
            await _recordReconciliationLog(
              client: client,
              snapshot: updated,
              serverStatus: serverStatus,
              mismatchReason: 'order_state_mismatch',
            );
            continue;
          }

          updated = updated.copyWith(
            orderId: serverOrderId.trim(),
            status: 'confirmed',
            reconciliationStatus: 'verified',
            updatedAt: DateTime.now().toUtc(),
          );
          _upsertSnapshot(updated);
          StabilityMetricsService.instance.increment(
            'payment_reconciliations',
            module: 'payment_reconciliation',
            payload: {'trigger': trigger},
          );
          await _recordReconciliationLog(
            client: client,
            snapshot: updated,
            serverStatus: serverStatus,
            mismatchReason: null,
          );
          continue;
        }

        final age = now.difference(snapshot.createdAt);
        if (age > _stuckPendingThreshold || nextAttempt > _maxVerificationAttempts) {
          updated = updated.copyWith(
            status: 'pending_review',
            reconciliationStatus: 'manual_review',
            updatedAt: DateTime.now().toUtc(),
          );
          _upsertSnapshot(updated);
          StabilityMetricsService.instance.increment(
            'failed_reconciliations',
            module: 'payment_reconciliation',
            payload: {'trigger': trigger},
          );
          await _recordReconciliationLog(
            client: client,
            snapshot: updated,
            serverStatus: serverStatus,
            mismatchReason: 'stuck_pending_payment',
          );
          continue;
        }

        await _recordReconciliationLog(
          client: client,
          snapshot: updated,
          serverStatus: serverStatus,
          mismatchReason: 'payment_not_confirmed_yet',
        );
      }

      _pruneSnapshots();
      await _persist();
      StabilityLogger.reconciliation(
        'Reconciliation completed trigger=$trigger pending=${pending.length}',
      );
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'payment_reconciliation_service.reconcile',
        error: error,
        stack: stack,
      );
    } finally {
      _reconcileInFlight = false;
    }
  }

  Future<Map<String, dynamic>?> _loadOrderRequestTokenRow({
    required SupabaseClient client,
    required String userId,
    required String orderRequestToken,
  }) async {
    try {
      final row = await client
          .from('order_request_tokens')
          .select('status, order_id, attempts, updated_at')
          .eq('user_id', userId)
          .eq('order_request_token', orderRequestToken)
          .limit(1)
          .maybeSingle();
      if (row is Map<String, dynamic>) {
        return row;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> _loadOrderStatusRow({
    required SupabaseClient client,
    required String orderId,
  }) async {
    try {
      final row = await client
          .from('orders')
          .select('status, updated_at')
          .eq('id', orderId)
          .limit(1)
          .maybeSingle();
      if (row is Map<String, dynamic>) {
        return row;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _recordReconciliationLog({
    required SupabaseClient client,
    required PaymentSnapshot snapshot,
    required String? serverStatus,
    required String? mismatchReason,
  }) async {
    try {
      await client.from('payment_reconciliation_logs').insert({
        'user_id': snapshot.userId,
        'order_request_token': snapshot.orderRequestToken,
        'payment_reference_id': snapshot.paymentReferenceId,
        'local_status': snapshot.status,
        'server_status': serverStatus,
        'reconciliation_status': snapshot.reconciliationStatus,
        'verification_attempts': snapshot.verificationAttempts,
        'mismatch_reason': mismatchReason,
        'payload': snapshot.toJson(),
      });
    } catch (_) {
      // Do not block checkout flow on logging failure.
    }
  }

  Future<void> _mutateByReference(
    String paymentReferenceId,
    PaymentSnapshot Function(PaymentSnapshot) mutate, {
    required String metricKey,
    required String logMessage,
  }) async {
    await initialize();
    final index = _snapshots.indexWhere(
      (snapshot) => snapshot.paymentReferenceId == paymentReferenceId,
    );
    if (index == -1) {
      return;
    }
    final next = mutate(_snapshots[index]);
    _snapshots[index] = next;
    await _persist();
    StabilityMetricsService.instance.increment(metricKey, module: 'payment');
    StabilityLogger.payment(logMessage);
  }

  void _upsertSnapshot(PaymentSnapshot snapshot) {
    final index = _snapshots.indexWhere(
      (item) => item.paymentReferenceId == snapshot.paymentReferenceId,
    );
    if (index == -1) {
      _snapshots.add(snapshot);
      return;
    }
    _snapshots[index] = snapshot;
  }

  Future<void> _restore() async {
    final raw = _prefs?.getString(_storageKey);
    if (raw == null || raw.trim().isEmpty) {
      return;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        return;
      }
      _snapshots
        ..clear()
        ..addAll(
          decoded
              .whereType<Map>()
              .map((row) => PaymentSnapshot.fromJson(Map<String, dynamic>.from(row)))
              .whereType<PaymentSnapshot>(),
        );
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'payment_reconciliation_service.restore',
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
    await prefs.setString(
      _storageKey,
      jsonEncode(_snapshots.map((item) => item.toJson()).toList()),
    );
  }

  void _pruneSnapshots() {
    final cutoff = DateTime.now().toUtc().subtract(const Duration(days: 2));
    _snapshots.removeWhere(
      (snapshot) =>
          !snapshot.isPending &&
          snapshot.updatedAt.isBefore(cutoff) &&
          (snapshot.status == 'confirmed' || snapshot.status == 'failed'),
    );
  }

  Future<void> dispose() async {
    await _connectivitySubscription?.cancel();
    _connectivitySubscription = null;
    _reconciliationTimer?.cancel();
    _reconciliationTimer = null;
  }

  SupabaseClient? get _clientOrNull {
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }
}
