import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../realtime/realtime_channel_controller.dart';
import '../services/error_logger.dart';
import 'security_event_service.dart';
import 'security_observability_service.dart';
import 'stability_logger.dart';
import 'stability_metrics_service.dart';

class SessionSecurityVerdict {
  const SessionSecurityVerdict._({
    required this.allowed,
    required this.reason,
  });

  final bool allowed;
  final String reason;

  const SessionSecurityVerdict.allowed() : this._(allowed: true, reason: 'ok');

  const SessionSecurityVerdict.denied(String reason)
      : this._(allowed: false, reason: reason);
}

class SessionSecurityService {
  SessionSecurityService._();

  static final SessionSecurityService instance = SessionSecurityService._();

  static const String _storageKey = 'session_security_state.v1';
  static const Duration _remoteValidationInterval = Duration(minutes: 2);
  static const Duration _staleSessionTtl = Duration(days: 30);

  SharedPreferences? _prefs;
  String? _deviceFingerprint;
  String? _deviceSeed;
  String? _lastSessionUserId;
  String? _lastRefreshTokenHash;
  DateTime? _lastRemoteValidationAt;
  int _sameRefreshHashHits = 0;
  int _sessionTrustScore = 100;
  RealtimeChannel? _revocationChannel;
  String? _revocationUserId;
  Timer? _revocationPollTimer;
  bool _initialized = false;

  String? get deviceFingerprint => _deviceFingerprint;

  Future<void> initialize() async {
    if (_initialized) {
      return;
    }
    _initialized = true;
    await StabilityMetricsService.instance.initialize();
    await SecurityEventService.instance.initialize();
    await SecurityObservabilityService.instance.initialize();
    _prefs = await SharedPreferences.getInstance();
    await _restore();
    _deviceSeed ??= _generateDeviceSeed();
    _deviceFingerprint = _buildDeviceFingerprint(_deviceSeed!);
    _startRevocationPolling();
    await _persist();
  }

  Future<void> recordAuthState({
    required AuthChangeEvent event,
    required Session? session,
  }) async {
    await initialize();
    final user = session?.user;
    if (event == AuthChangeEvent.signedOut || user == null) {
      if (_lastSessionUserId != null) {
        StabilityLogger.session(
          'Session ended user=$_lastSessionUserId event=${event.name}',
        );
      }
      await _clearRevocationSubscription();
      _lastSessionUserId = null;
      _lastRefreshTokenHash = null;
      _sameRefreshHashHits = 0;
      _sessionTrustScore = 100;
      await _persist();
      return;
    }

    final currentSession = session;
    if (currentSession == null) {
      await _persist();
      return;
    }

    final currentUserId = user.id;
    if (_lastSessionUserId != null && _lastSessionUserId != currentUserId) {
      StabilityMetricsService.instance.increment(
        'stale_sessions',
        module: 'session_security',
      );
      StabilityLogger.session(
        'Detected session jump from user=$_lastSessionUserId to user=$currentUserId',
      );
    }
    _lastSessionUserId = currentUserId;
    await _ensureRevocationSubscription(
      userId: currentUserId,
      session: currentSession,
    );

    final refreshHash = _hash(currentSession.refreshToken ?? '');
    final shouldTrackRefreshReuse = event == AuthChangeEvent.tokenRefreshed;
    if (_lastRefreshTokenHash != null &&
        _lastRefreshTokenHash == refreshHash &&
        shouldTrackRefreshReuse) {
      _sameRefreshHashHits += 1;
      if (_sameRefreshHashHits >= 4) {
        StabilityMetricsService.instance.increment(
          'suspicious_sessions',
          module: 'session_security',
          payload: {'reason': 'refresh_token_not_rotating'},
        );
        StabilityLogger.session(
          'Suspicious refresh token reuse detected for user=$currentUserId',
        );
        _sessionTrustScore = (_sessionTrustScore - 10).clamp(0, 100).toInt();
        SecurityObservabilityService.instance.incrementLocal(
          'suspicious_sessions',
          payload: {'reason': 'refresh_token_not_rotating'},
        );
        SecurityEventService.instance.record(
          eventKey: 'refresh_token_reuse_detected',
          severity: 'high',
          payload: {'user_id': currentUserId},
        );
      }
    } else {
      _sameRefreshHashHits = 0;
      _lastRefreshTokenHash = refreshHash;
    }

    await _upsertRemoteSession(
      userId: currentUserId,
      session: currentSession,
      refreshHash: refreshHash,
    );
    _lastRemoteValidationAt = DateTime.now().toUtc();
    await _cleanupStaleRemoteSessions(currentUserId);
    await _persist();
  }

  Future<void> markSuspicious({
    required String userId,
    required String reason,
    int score = 1,
  }) async {
    await initialize();
    StabilityMetricsService.instance.increment(
      'suspicious_sessions',
      module: 'session_security',
      payload: {'reason': reason},
    );
    SecurityObservabilityService.instance.incrementLocal(
      'suspicious_sessions',
      payload: {'reason': reason},
    );
    SecurityEventService.instance.record(
      eventKey: 'suspicious_session_detected',
      severity: score >= 8 ? 'high' : 'medium',
      payload: {
        'user_id': userId,
        'reason': reason,
        'score': score,
      },
    );
    final client = _clientOrNull;
    final fingerprint = _deviceFingerprint;
    if (client == null || fingerprint == null || fingerprint.isEmpty) {
      return;
    }
    try {
      await client
          .from('customer_sessions')
          .update({
            'suspicious_score': score,
            'trust_score': (_sessionTrustScore - 10).clamp(0, 100),
            'requires_reauth': score >= 8,
            'last_seen_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('user_id', userId)
          .eq('device_fingerprint', fingerprint);

      await client.rpc(
        'register_suspicious_session',
        params: {
          'p_user_id': userId,
          'p_session_id': client.auth.currentSession == null
              ? null
              : _sessionIdOf(client.auth.currentSession!.accessToken),
          'p_device_fingerprint': fingerprint,
          'p_ip_info': _platformInfo(),
          'p_geo_info': <String, dynamic>{},
          'p_anomaly_type': reason,
          'p_trust_score': (_sessionTrustScore - 10).clamp(0, 100),
          'p_risk_score': (score * 10).clamp(0, 100),
          'p_requires_reauth': score >= 6,
          'p_force_logout': score >= 9,
        },
      );
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'session_security_service.mark_suspicious',
        error: error,
        stack: stack,
      );
    }
    _sessionTrustScore =
        (_sessionTrustScore - max(1, score)).clamp(0, 100).toInt();
    StabilityLogger.session(
        'Marked session suspicious user=$userId reason=$reason');
  }

  Future<SessionSecurityVerdict> validateCurrentSession({
    required Session session,
    bool forceRemoteCheck = false,
  }) async {
    await initialize();

    final client = _clientOrNull;
    final fingerprint = _deviceFingerprint;
    if (client == null || fingerprint == null || fingerprint.isEmpty) {
      return const SessionSecurityVerdict.allowed();
    }

    final now = DateTime.now().toUtc();
    if (!forceRemoteCheck &&
        _lastRemoteValidationAt != null &&
        now.difference(_lastRemoteValidationAt!) < _remoteValidationInterval) {
      return const SessionSecurityVerdict.allowed();
    }

    try {
      final revocationVerdict = await _checkRevocationState(session);
      if (revocationVerdict != null && !revocationVerdict.allowed) {
        StabilityMetricsService.instance.increment(
          'auth_channel_kills',
          module: 'auth_revalidation',
          payload: {'reason': revocationVerdict.reason},
        );
        SecurityObservabilityService.instance.incrementLocal(
          'auth_channel_kills',
          payload: {'reason': revocationVerdict.reason},
        );
        SecurityEventService.instance.record(
          eventKey: 'auth_revalidation_failed',
          severity: 'high',
          payload: {'reason': revocationVerdict.reason},
        );
        return revocationVerdict;
      }

      final row = await client
          .from('customer_sessions')
          .select(
            'is_active, suspicious_score, session_id, refresh_token_hash, last_seen_at',
          )
          .eq('user_id', session.user.id)
          .eq('device_fingerprint', fingerprint)
          .limit(1)
          .maybeSingle();

      if (row is Map<String, dynamic>) {
        final isActive = row['is_active'] == true;
        final suspiciousScore = _toInt(row['suspicious_score']) ?? 0;
        final remoteSessionId = row['session_id']?.toString().trim() ?? '';
        final remoteRefreshHash =
            row['refresh_token_hash']?.toString().trim() ?? '';

        if (!isActive) {
          StabilityMetricsService.instance.increment(
            'stale_sessions',
            module: 'session_security',
            payload: {'reason': 'session_revoked'},
          );
          SecurityEventService.instance.record(
            eventKey: 'session_revoked_remote',
            severity: 'high',
            payload: {'user_id': session.user.id},
          );
          return const SessionSecurityVerdict.denied('session_revoked');
        }

        if (suspiciousScore >= 8) {
          StabilityMetricsService.instance.increment(
            'suspicious_sessions',
            module: 'session_security',
            payload: {'reason': 'high_suspicion_score'},
          );
          SecurityEventService.instance.record(
            eventKey: 'high_suspicion_score',
            severity: 'high',
            payload: {'user_id': session.user.id, 'score': suspiciousScore},
          );
          return const SessionSecurityVerdict.denied('high_suspicion_score');
        }
StabilityLogger.session(
  'LOCAL_SESSION_ID=${_sessionIdOf(session.accessToken)}',
);
        final localSessionId = _sessionIdOf(session.accessToken);
        if (remoteSessionId.isNotEmpty && remoteSessionId != localSessionId) {
          await markSuspicious(
            userId: session.user.id,
            reason: 'session_id_mismatch',
            score: suspiciousScore + 1,
          );
          if (suspiciousScore >= 4) {
            return const SessionSecurityVerdict.denied('session_id_mismatch');
          }
        }

        final localRefreshHash = _hash(session.refreshToken ?? '');
        if (remoteRefreshHash.isNotEmpty &&
            remoteRefreshHash != localRefreshHash &&
            suspiciousScore >= 5) {
          await markSuspicious(
            userId: session.user.id,
            reason: 'refresh_token_mismatch',
            score: suspiciousScore + 1,
          );
          return const SessionSecurityVerdict.denied('refresh_token_mismatch');
        }
      }

      await _upsertRemoteSession(
        userId: session.user.id,
        session: session,
        refreshHash: _hash(session.refreshToken ?? ''),
      );
      _lastRemoteValidationAt = now;
      await _cleanupStaleRemoteSessions(session.user.id);
      await _persist();
      return const SessionSecurityVerdict.allowed();
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'session_security_service.validate_current_session',
        error: error,
        stack: stack,
      );
      return const SessionSecurityVerdict.allowed();
    }
  }

  Future<void> forceLocalSignOut({required String reason}) async {
    final client = _clientOrNull;
    if (client == null) {
      return;
    }
    await _clearRevocationSubscription();
    try {
      await client.auth.signOut(scope: SignOutScope.local);
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'session_security_service.force_local_signout',
        error: error,
        stack: stack,
      );
    }
    SecurityObservabilityService.instance.incrementLocal(
      'auth_channel_kills',
      payload: {'reason': reason},
    );
    SecurityEventService.instance.record(
      eventKey: 'force_local_signout',
      severity: 'high',
      payload: {'reason': reason},
      flushNow: true,
    );
    StabilityLogger.revocation(
        '[REVOCATION] Forced local sign-out reason=$reason');
  }

  Future<void> _upsertRemoteSession({
    required String userId,
    required Session session,
    required String refreshHash,
  }) async {
    final client = _clientOrNull;
    if (client == null || _deviceFingerprint == null) {
      return;
    }

    final nowIso = DateTime.now().toUtc().toIso8601String();
    final sessionId = _sessionIdOf(session.accessToken);
    final payload = {
      'user_id': userId,
      'device_fingerprint': _deviceFingerprint,
      'refresh_token_hash': refreshHash,
      'session_id': sessionId,
      'app_version': 'customer',
      'ip_info': _platformInfo(),
      'is_active': true,
      'last_seen_at': nowIso,
      'updated_at': nowIso,
    };

    try {
      await client.from('customer_sessions').upsert(
            payload,
            onConflict: 'user_id,device_fingerprint',
          );

      final sessions = await client
          .from('customer_sessions')
          .select('device_fingerprint, suspicious_score')
          .eq('user_id', userId)
          .eq('is_active', true)
          .limit(10);

      final activeSessions = (sessions as List<dynamic>).length;
      if (activeSessions >= 5) {
        StabilityMetricsService.instance.increment(
          'suspicious_sessions',
          module: 'session_security',
          payload: {'reason': 'too_many_devices'},
        );
        StabilityLogger.session(
          'Detected many active sessions for user=$userId count=$activeSessions',
        );
      }
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'session_security_service.upsert_remote_session',
        error: error,
        stack: stack,
      );
    }
  }

  Future<void> _cleanupStaleRemoteSessions(String userId) async {
    final client = _clientOrNull;
    if (client == null) {
      return;
    }
    final staleBefore =
        DateTime.now().toUtc().subtract(_staleSessionTtl).toIso8601String();
    try {
      await client
          .from('customer_sessions')
          .update({
            'is_active': false,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('user_id', userId)
          .eq('is_active', true)
          .lt('last_seen_at', staleBefore);
    } catch (_) {
      // Avoid blocking critical auth/session flow on optional cleanup failures.
    }
  }

  Future<SessionSecurityVerdict?> _checkRevocationState(Session session) async {
    final client = _clientOrNull;
    final fingerprint = _deviceFingerprint;
    if (client == null || fingerprint == null || fingerprint.isEmpty) {
      return null;
    }
    try {
      final response = await client.rpc(
        'check_session_revocation',
        params: {
          'p_session_id': _sessionIdOf(session.accessToken),
          'p_device_fingerprint': fingerprint,
        },
      );

      if (response is! Map) {
        return null;
      }

      final map = Map<String, dynamic>.from(response);
      final isValid = map['is_valid'] == true;
      if (isValid) {
        return const SessionSecurityVerdict.allowed();
      }
      final reason = map['reason']?.toString().trim().isNotEmpty == true
          ? map['reason'].toString().trim()
          : 'auth_revalidation_failed';
      return SessionSecurityVerdict.denied(reason);
    } catch (_) {
      return null;
    }
  }

  Future<void> _ensureRevocationSubscription({
    required String userId,
    required Session session,
  }) async {
    final client = _clientOrNull;
    if (client == null) {
      return;
    }
    if (client.auth.currentUser == null) {
      await _clearRevocationSubscription();
      return;
    }
    if (_revocationUserId == userId && _revocationChannel != null) {
      return;
    }

    await _clearRevocationSubscription();

    final sessionId = _sessionIdOf(session.accessToken);
    final fingerprint = _deviceFingerprint;
    if (fingerprint == null || fingerprint.isEmpty) {
      return;
    }

    _revocationUserId = userId;
    final channel = client.channel(
      'security-revocation-$userId',
    );
    _revocationChannel = channel;
    channel
        .onPostgresChanges(
      event: PostgresChangeEvent.insert,
      schema: 'public',
      table: 'revoked_sessions',
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'user_id',
        value: userId,
      ),
      callback: (payload) {
        final row = payload.newRecord;
        final globalRevoke = _toBool(row['global_revoke']) ?? false;
        final remoteSessionId = row['session_id']?.toString().trim() ?? '';
        StabilityLogger.session(
  'REMOTE_SESSION_ID=$remoteSessionId',
);
        final remoteFingerprint =
            row['device_fingerprint']?.toString().trim() ?? '';

        final applies = globalRevoke ||
            (remoteSessionId.isNotEmpty && remoteSessionId == sessionId) ||
            (remoteFingerprint.isNotEmpty && remoteFingerprint == fingerprint);
        if (!applies) {
          return;
        }

        final reason =
            row['revoke_reason']?.toString().trim().isNotEmpty == true
                ? row['revoke_reason'].toString().trim()
                : 'session_revoked';
        unawaited(_handleRevocationSignal(reason: reason));
      },
    )
        .subscribe((status, [error]) {
      if (status == RealtimeSubscribeStatus.subscribed) {
        StabilityLogger.revocation(
          '[REVOCATION] Subscription Created topic=security-revocation-$userId',
        );
      } else if (status == RealtimeSubscribeStatus.channelError ||
          status == RealtimeSubscribeStatus.timedOut) {
        StabilityLogger.authRevalidation(
          '[AUTH_REVALIDATION] Revocation feed status=$status error=${error ?? '-'}',
        );
      } else if (status == RealtimeSubscribeStatus.closed) {
        StabilityLogger.revocation(
          '[REVOCATION] Connection Closed topic=security-revocation-$userId',
        );
      }
    });
  }

  Future<void> _handleRevocationSignal({required String reason}) async {
    await RealtimeChannelController.terminateAllAuthenticatedChannels(
      reason: reason,
    );
    SecurityEventService.instance.record(
      eventKey: 'session_revocation_signal',
      severity: 'high',
      payload: {'reason': reason},
      flushNow: true,
    );
    SecurityObservabilityService.instance.incrementLocal(
      'auth_channel_kills',
      payload: {'reason': reason},
    );
    await forceLocalSignOut(reason: reason);
  }

  Future<void> _clearRevocationSubscription() async {
    final client = _clientOrNull;
    final channel = _revocationChannel;
    _revocationChannel = null;
    _revocationUserId = null;
    StabilityLogger.revocation(
      '[REVOCATION] Realtime Cleanup Started topic=security-revocation',
    );
    if (client == null || channel == null) {
      StabilityLogger.revocation(
        '[REVOCATION] Realtime Cleanup Finished topic=security-revocation',
      );
      return;
    }
    try {
      await client.removeChannel(channel);
      StabilityLogger.revocation(
        '[REVOCATION] Channel Removed Successfully topic=security-revocation',
      );
      StabilityLogger.revocation(
        '[REVOCATION] Subscription Removed topic=security-revocation',
      );
    } catch (_) {}
    StabilityLogger.revocation(
      '[REVOCATION] Realtime Cleanup Finished topic=security-revocation',
    );
  }

  void _startRevocationPolling() {
    if (_revocationPollTimer != null) {
      return;
    }
    _revocationPollTimer = Timer.periodic(const Duration(seconds: 40), (_) {
      final client = _clientOrNull;
      final session = client?.auth.currentSession;
      if (session == null) {
        return;
      }
      unawaited(
        validateCurrentSession(
          session: session,
          forceRemoteCheck: true,
        ),
      );
    });
  }

  String _buildDeviceFingerprint(String seed) {
    final platform = defaultTargetPlatform.name;
    final locale = PlatformDispatcher.instance.locale.toLanguageTag();
    final fingerprintSource = '$platform|$locale|$kIsWeb|$seed';
    return _hash(fingerprintSource).substring(0, 40);
  }

  String _platformInfo() {
    final platform = defaultTargetPlatform.name;
    final locale = PlatformDispatcher.instance.locale.toLanguageTag();
    return 'platform=$platform; locale=$locale; web=$kIsWeb';
  }

  String _hash(String source) {
    return sha256.convert(utf8.encode(source)).toString();
  }

 String _sessionIdOf(String accessToken) {
  return _deviceFingerprint ?? 'unknown';
}
  String _generateDeviceSeed() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();
  }

  Future<void> _restore() async {
    final raw = _prefs?.getString(_storageKey);
    if (raw == null || raw.trim().isEmpty) {
      return;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return;
      }
      _deviceFingerprint = decoded['device_fingerprint']?.toString();
      _deviceSeed = decoded['device_seed']?.toString();
      _lastSessionUserId = decoded['last_user_id']?.toString();
      _lastRefreshTokenHash = decoded['refresh_token_hash']?.toString();
      _sameRefreshHashHits =
          (decoded['same_refresh_hash_hits'] as num?)?.toInt() ?? 0;
      _sessionTrustScore =
          (decoded['session_trust_score'] as num?)?.toInt() ?? 100;
      _lastRemoteValidationAt = DateTime.tryParse(
        decoded['last_remote_validation_at']?.toString() ?? '',
      )?.toUtc();
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'session_security_service.restore',
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
      jsonEncode({
        'device_fingerprint': _deviceFingerprint,
        'device_seed': _deviceSeed,
        'last_user_id': _lastSessionUserId,
        'refresh_token_hash': _lastRefreshTokenHash,
        'same_refresh_hash_hits': _sameRefreshHashHits,
        'session_trust_score': _sessionTrustScore,
        'last_remote_validation_at': _lastRemoteValidationAt?.toIso8601String(),
      }),
    );
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

  bool? _toBool(Object? value) {
    if (value is bool) {
      return value;
    }
    final text = value?.toString().trim().toLowerCase();
    if (text == null || text.isEmpty) {
      return null;
    }
    if (text == 'true' || text == '1' || text == 'yes') {
      return true;
    }
    if (text == 'false' || text == '0' || text == 'no') {
      return false;
    }
    return null;
  }

  SupabaseClient? get _clientOrNull {
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }
}
