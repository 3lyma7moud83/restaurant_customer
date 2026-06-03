import 'dart:async';
import 'dart:collection';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/error_logger.dart';
import 'security_event_service.dart';
import 'stability_logger.dart';

class RpcSecurityEnvelope {
  const RpcSecurityEnvelope({
    required this.requestId,
    required this.nonce,
    required this.expiresAt,
    required this.signature,
  });

  final String requestId;
  final String nonce;
  final DateTime expiresAt;
  final String signature;
}

class RpcSecurityService {
  RpcSecurityService._();

  static final RpcSecurityService instance = RpcSecurityService._();

  static const int _maxLocalReplayEntries = 512;

  final Map<String, DateTime> _recentActionWindow = <String, DateTime>{};
  final Queue<String> _recentActionOrder = Queue<String>();

  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) {
      return;
    }
    _initialized = true;
    await SecurityEventService.instance.initialize();
  }

  bool allowLocalAction(
    String actionKey, {
    Duration window = const Duration(seconds: 4),
  }) {
    final normalized = actionKey.trim();
    if (normalized.isEmpty) {
      return true;
    }

    final now = DateTime.now().toUtc();
    final previous = _recentActionWindow[normalized];
    if (previous != null && now.difference(previous) < window) {
      StabilityLogger.rpcReplay(
        'Local replay window blocked action=$normalized',
      );
      SecurityEventService.instance.record(
        eventKey: 'rpc_local_replay_blocked',
        severity: 'medium',
        payload: {
          'action_key': normalized,
          'window_ms': window.inMilliseconds,
        },
      );
      return false;
    }

    _recentActionWindow[normalized] = now;
    _recentActionOrder.add(normalized);
    _trimLocalReplayCache();
    return true;
  }

  Future<RpcSecurityEnvelope> prepareEnvelope({
    required String rpcName,
    required Map<String, dynamic> payload,
    String actionScope = 'default',
    Duration ttl = const Duration(minutes: 2),
    String? requestId,
  }) async {
    await initialize();
    final client = _client;

    final response = await client.rpc(
      'prepare_rpc_nonce',
      params: {
        'p_rpc_name': rpcName,
        'p_action_scope': actionScope,
        'p_request_id': requestId,
        'p_payload': payload,
        'p_valid_for_seconds': ttl.inSeconds,
      },
    );

    final map = _coerceSingleRow(response);
    if (map == null) {
      throw const PostgrestException(
        message: 'Failed to prepare RPC nonce envelope.',
      );
    }

    final preparedRequestId = map['request_id']?.toString().trim() ?? '';
    final nonce = map['nonce']?.toString().trim() ?? '';
    final signature = map['request_signature']?.toString().trim() ?? '';
    final expiresAt = DateTime.tryParse(
          map['expires_at']?.toString() ?? '',
        )?.toUtc() ??
        DateTime.now().toUtc().add(ttl);

    if (preparedRequestId.isEmpty || nonce.isEmpty || signature.isEmpty) {
      throw const PostgrestException(
        message: 'Invalid RPC nonce envelope response.',
      );
    }

    return RpcSecurityEnvelope(
      requestId: preparedRequestId,
      nonce: nonce,
      expiresAt: expiresAt,
      signature: signature,
    );
  }

  Future<void> consumeEnvelopeOrThrow({
    required String rpcName,
    required String actionScope,
    required RpcSecurityEnvelope envelope,
    required Map<String, dynamic> payload,
  }) async {
    await initialize();
    final client = _client;

    final response = await client.rpc(
      'verify_and_consume_rpc_nonce',
      params: {
        'p_rpc_name': rpcName,
        'p_action_scope': actionScope,
        'p_request_id': envelope.requestId,
        'p_nonce': envelope.nonce,
        'p_request_signature': envelope.signature,
        'p_payload': payload,
        'p_raise_on_failure': true,
      },
    );

    final allowed = response == true ||
        (response is Map && response['result'] == true) ||
        (response is List && response.isNotEmpty && response.first == true);

    if (!allowed) {
      SecurityEventService.instance.record(
        eventKey: 'rpc_nonce_consume_denied',
        severity: 'high',
        payload: {
          'rpc_name': rpcName,
          'action_scope': actionScope,
          'request_id': envelope.requestId,
        },
      );
      throw const PostgrestException(message: 'RPC nonce consume failed.');
    }
  }

  Future<T> guardedRpc<T>({
    required String rpcName,
    required String actionScope,
    required Map<String, dynamic> payload,
    required Future<T> Function(RpcSecurityEnvelope envelope) execute,
    Duration ttl = const Duration(minutes: 2),
  }) async {
    final actionKey = '$rpcName|$actionScope|${payload.toString()}';
    if (!allowLocalAction(actionKey)) {
      throw const PostgrestException(message: 'Local replay block triggered.');
    }

    final envelope = await prepareEnvelope(
      rpcName: rpcName,
      payload: payload,
      actionScope: actionScope,
      ttl: ttl,
    );

    try {
      final result = await execute(envelope);
      return result;
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'rpc_security_service.guarded_rpc',
        action: rpcName,
        error: error,
        stack: stack,
      );
      rethrow;
    }
  }

  Map<String, dynamic>? _coerceSingleRow(dynamic response) {
    if (response is Map) {
      return Map<String, dynamic>.from(response);
    }
    if (response is List && response.isNotEmpty && response.first is Map) {
      return Map<String, dynamic>.from(response.first as Map);
    }
    return null;
  }

  void _trimLocalReplayCache() {
    while (_recentActionOrder.length > _maxLocalReplayEntries) {
      final oldest = _recentActionOrder.removeFirst();
      _recentActionWindow.remove(oldest);
    }
  }

  SupabaseClient get _client => Supabase.instance.client;
}
