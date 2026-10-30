import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'session_manager.dart';

class ComplaintSubmissionException implements Exception {
  const ComplaintSubmissionException(this.message);
  final String message;
  @override
  String toString() => message;
}

class ComplaintsService {
  ComplaintsService({
    required SupabaseClient client,
    required Future<Session?> Function() validateSession,
    this.requestTimeout = const Duration(seconds: 15),
  })  : _client = client,
        _validateSession = validateSession;

  static final ComplaintsService _shared = ComplaintsService(
    client: Supabase.instance.client,
    validateSession: () => SessionManager.instance.ensureValidSession(
      requireSession: true,
    ),
  );
  final SupabaseClient _client;
  final Future<Session?> Function() _validateSession;
  final Duration requestTimeout;
  final Map<String, Future<String>> _inFlight = {};
  static final RegExp _uuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );
  static const _columns =
      'id,user_id,restaurant_id,complaint_title,complaint_message';
  static const _uncertainMessage =
      'تعذر تأكيد حفظ الشكوى. تحقق من الاتصال ثم اضغط إرسال مرة أخرى؛ سنتحقق من الحفظ أولًا لتجنب التكرار.';

  static Future<String> submitComplaint({
    required String userId,
    required String title,
    required String description,
    String? restaurantId,
    String? orderId,
  }) =>
      _shared.submit(
        userId: userId,
        title: title,
        description: description,
        restaurantId: restaurantId,
        orderId: orderId,
      );

  Future<String> submit({
    required String userId,
    required String title,
    required String description,
    String? restaurantId,
    String? orderId,
  }) async {
    final normalizedTitle = title.trim();
    final normalizedDescription = description.trim();
    final normalizedRestaurant = _nonEmpty(restaurantId);
    final normalizedOrder = _nonEmpty(orderId);
    if (normalizedTitle.length < 4 || normalizedTitle.length > 120) {
      throw const ComplaintSubmissionException(
        'عنوان الشكوى يجب أن يكون بين 4 و120 حرفًا.',
      );
    }
    if (normalizedDescription.length < 10 ||
        normalizedDescription.length > 1000) {
      throw const ComplaintSubmissionException(
        'وصف الشكوى يجب أن يكون بين 10 و1000 حرف.',
      );
    }
    if ((normalizedRestaurant != null &&
            !_uuid.hasMatch(normalizedRestaurant)) ||
        (normalizedOrder != null && !_uuid.hasMatch(normalizedOrder))) {
      throw const ComplaintSubmissionException(
        'تعذر تحديد المطعم المرتبط بالشكوى. افتح صفحة المطعم مجددًا.',
      );
    }
    // Store only a fingerprint and a random ID, never complaint text or tokens.
    // A lost response or closing the sheet must not generate a new INSERT ID.
    final fingerprint = sha256
        .convert(utf8.encode(jsonEncode([
          _client.rest.url,
          userId,
          normalizedRestaurant,
          normalizedOrder,
          normalizedTitle,
          normalizedDescription,
        ])))
        .toString();
    final existing = _inFlight[fingerprint];
    if (existing != null) return existing;
    final operation = _submitOnce(
      userId: userId,
      title: normalizedTitle,
      description: normalizedDescription,
      restaurantId: normalizedRestaurant,
      orderId: normalizedOrder,
      storageKey: 'complaint.pending.v1.$fingerprint',
    );
    _inFlight[fingerprint] = operation;
    try {
      return await operation;
    } finally {
      _inFlight.remove(fingerprint);
    }
  }

  Future<String> _submitOnce({
    required String userId,
    required String title,
    required String description,
    required String? restaurantId,
    required String? orderId,
    required String storageKey,
  }) async {
    try {
      final session = await _validateSession().timeout(requestTimeout);
      if (session == null || session.user.id != userId) {
        throw const ComplaintSubmissionException('سجل الدخول لإرسال الشكوى.');
      }
      _checkCurrentUser(userId);
      final targetRestaurant = await _resolveRestaurant(
        userId: userId,
        restaurantId: restaurantId,
        orderId: orderId,
      );
      final prefs = await SharedPreferences.getInstance();
      final pendingId = prefs.getString(storageKey);
      final requestId = pendingId ?? _newRequestId();
      final payload = <String, dynamic>{
        'id': requestId,
        'user_id': userId,
        'restaurant_id': targetRestaurant,
        'customer_name': _customerName(session.user),
        'customer_phone': _customerPhone(session.user),
        'complaint_title': title,
        'complaint_message': description,
      };
      if (pendingId != null) {
        final saved = await _findSaved(requestId, userId);
        if (saved != null) {
          _verifySaved(saved, payload);
          _checkCurrentUser(userId);
          await prefs.remove(storageKey);
          return requestId;
        }
      } else if (!await prefs.setString(storageKey, requestId)) {
        throw const ComplaintSubmissionException(
          'تعذر تجهيز إرسال آمن للشكوى. حاول مرة أخرى.',
        );
      }
      _checkCurrentUser(userId);
      Map<String, dynamic> saved;
      try {
        saved = await _client
            .from('complaints')
            .insert(payload)
            .select(_columns)
            .single()
            .timeout(requestTimeout);
      } on PostgrestException catch (error) {
        if (error.code != '23505') rethrow;
        // A previous timed-out INSERT can finish after reconciliation. The
        // primary key prevents a second row even in this race.
        final existing = await _findSaved(requestId, userId);
        if (existing == null) rethrow;
        saved = existing;
      }
      _verifySaved(saved, payload);
      _checkCurrentUser(userId);
      await prefs.remove(storageKey);
      return requestId;
    } on ComplaintSubmissionException {
      rethrow;
    } on PostgrestException catch (error) {
      if (error.code == '42501') {
        throw const ComplaintSubmissionException(
          'تعذر إرسال الشكوى بسبب صلاحيات الحساب. سجل الدخول مجددًا أو تواصل مع الدعم.',
        );
      }
      if (error.code == 'PGRST301' || error.code == 'PGRST303') {
        throw const ComplaintSubmissionException(
            'انتهت الجلسة. سجل الدخول مجددًا.');
      }
      // Do not expose database details or retry another schema/INSERT.
      throw const ComplaintSubmissionException(
        'تعذر حفظ الشكوى في الخدمة. حاول لاحقًا أو تواصل مع الدعم.',
      );
    } on AuthException {
      throw const ComplaintSubmissionException('سجل الدخول لإرسال الشكوى.');
    } on SessionExpiredException {
      throw const ComplaintSubmissionException(
          'انتهت الجلسة. سجل الدخول مجددًا.');
    } catch (_) {
      // Timeout/network failure does not prove whether INSERT committed.
      // Reconcile the preserved ID only on the user's next explicit attempt.
      throw const ComplaintSubmissionException(_uncertainMessage);
    }
  }

  Future<String?> _resolveRestaurant({
    required String userId,
    required String? restaurantId,
    required String? orderId,
  }) async {
    if (orderId == null) return restaurantId;
    final row = await _client
        .from('orders')
        .select('restaurant_id')
        .eq('id', orderId)
        .eq('customer_id', userId)
        .maybeSingle()
        .timeout(requestTimeout);
    final orderRestaurant = _nonEmpty(row?['restaurant_id']?.toString());
    if (orderRestaurant == null ||
        (restaurantId != null && restaurantId != orderRestaurant)) {
      throw const ComplaintSubmissionException(
        'الطلب المحدد غير متاح لحسابك أو لا يخص هذا المطعم.',
      );
    }
    return orderRestaurant;
  }

  Future<Map<String, dynamic>?> _findSaved(String id, String userId) {
    _checkCurrentUser(userId);
    return _client
        .from('complaints')
        .select(_columns)
        .eq('id', id)
        .eq('user_id', userId)
        .maybeSingle()
        .timeout(requestTimeout);
  }

  void _verifySaved(Map<String, dynamic> saved, Map<String, dynamic> payload) {
    for (final field in _columns.split(',')) {
      if (saved[field] != payload[field]) {
        throw const ComplaintSubmissionException(_uncertainMessage);
      }
    }
  }

  void _checkCurrentUser(String userId) {
    if (_client.auth.currentUser?.id != userId) {
      throw const ComplaintSubmissionException('سجل الدخول لإرسال الشكوى.');
    }
  }

  static String? _nonEmpty(String? value) {
    final normalized = value?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }

  static String _customerName(User user) {
    for (final candidate in [
      user.userMetadata?['name'],
      user.userMetadata?['full_name'],
      user.userMetadata?['display_name'],
      user.email
    ]) {
      final value = _nonEmpty(candidate?.toString());
      if (value != null) return value;
    }
    return 'عميل';
  }

  static String? _customerPhone(User user) =>
      _nonEmpty(user.phone) ??
      _nonEmpty(user.userMetadata?['phone']?.toString());

  static String _newRequestId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex =
        bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }
}
