import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/stability/security_event_service.dart';
import '../core/stability/security_observability_service.dart';
import '../core/stability/session_security_service.dart';
import '../core/services/error_logger.dart';
import '../core/theme/app_theme.dart';
import '../core/ui/input_focus_guard.dart';
import '../pages/auth/login_page.dart';

class SessionExpiredException implements Exception {
  final String message;

  const SessionExpiredException([
    this.message = 'انتهت الجلسة. سجل الدخول مرة أخرى.',
  ]);

  @override
  String toString() => message;
}

class SessionManager {
  SessionManager._();

  static final SessionManager instance = SessionManager._();
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  final SupabaseClient _client = Supabase.instance.client;

  StreamSubscription<AuthState>? _authSubscription;
  Future<Session?>? _refreshFuture;
  Future<void>? _pendingSecuritySync;

  bool _initialized = false;
  bool _hadAuthenticatedSession = false;
  bool _redirectInFlight = false;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    await SessionSecurityService.instance.initialize();
    final initialSession = _client.auth.currentSession;
    _hadAuthenticatedSession = initialSession != null;

    _authSubscription = _client.auth.onAuthStateChange.listen((data) {
      unawaited(_syncSecurityState(event: data.event, session: data.session));
      if (data.event == AuthChangeEvent.signedOut) {
        _hadAuthenticatedSession = false;
        return;
      }
      final session = data.session;
      if (session != null) {
        _hadAuthenticatedSession = true;
      }
    });

    if (initialSession != null) {
      await _syncSecurityState(
        event: AuthChangeEvent.initialSession,
        session: initialSession,
      );
    }
  }

  Future<void> dispose() async {
    await _authSubscription?.cancel();
    _authSubscription = null;
    _initialized = false;
  }

  Future<Session?> ensureValidSession({
    bool requireSession = false,
  }) async {
    final session = _client.auth.currentSession;
    if (session == null) {
      if (requireSession) {
        await redirectToLogin();
      }
      return null;
    }

    _hadAuthenticatedSession = true;
    await _waitForPendingSecuritySync();

    if (!_shouldRefreshSession(session)) {
      return _enforceSessionSecurity(
        session,
        requireSession: requireSession,
      );
    }

    final refreshed = await _refreshSessionOrRedirect(
      requireSession: requireSession,
    );
    return _enforceSessionSecurity(
      refreshed ?? _client.auth.currentSession,
      requireSession: requireSession,
    );
  }

  Future<T?> runWithValidSession<T>(
    Future<T> Function() action, {
    bool requireSession = false,
  }) async {
    final session = await ensureValidSession(requireSession: requireSession);
    if (session == null &&
        (requireSession || (_hadAuthenticatedSession && _redirectInFlight))) {
      return null;
    }

    try {
      return await action();
    } on PostgrestException catch (error) {
      if (!_isJwtExpiredError(error)) {
        unawaited(
          ErrorLogger.logError(
            module: 'session_manager.runWithValidSession.postgrest_exception',
            action: 'rethrow_non_expired',
            error: error,
          ),
        );
        rethrow;
      }

      unawaited(
        ErrorLogger.logError(
          module: 'session_manager.runWithValidSession.postgrest_exception',
          action: 'refresh_after_expired',
          error: error,
        ),
      );
      final refreshedSession = await _refreshSessionOrRedirect(
        requireSession: requireSession,
      );
      if (refreshedSession == null) {
        return null;
      }

      return action();
    } on AuthException catch (error) {
      if (!_isSessionExpiredMessage(error.message)) {
        unawaited(
          ErrorLogger.logError(
            module: 'session_manager.runWithValidSession.auth_exception',
            action: 'rethrow_non_expired',
            error: error,
          ),
        );
        rethrow;
      }

      unawaited(
        ErrorLogger.logError(
          module: 'session_manager.runWithValidSession.auth_exception',
          action: 'redirect_after_expired',
          error: error,
        ),
      );
      await _handleInvalidSession(
        redirectToLoginPage: requireSession || _hadAuthenticatedSession,
      );
      return null;
    }
  }

  Future<void> redirectToLogin() async {
    if (_redirectInFlight) return;
    _redirectInFlight = true;

    void pushLogin() {
      final navigator = navigatorKey.currentState;
      if (navigator == null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_redirectInFlight) {
            pushLogin();
          }
        });
        return;
      }

      unawaited(
        InputFocusGuard.prepareForUiTransition().then((_) {
          if (!_redirectInFlight) {
            return;
          }
          navigator
              .pushAndRemoveUntil(
                AppTheme.platformPageRoute<void>(
                  builder: (_) => const LoginPage(),
                ),
                (_) => false,
              )
              .whenComplete(() => _redirectInFlight = false);
        }),
      );
    }

    pushLogin();
  }

  Future<Session?> refreshSession() {
    return _refreshSessionOrRedirect(requireSession: true);
  }

  Future<Session?> _enforceSessionSecurity(
    Session? session, {
    required bool requireSession,
  }) async {
    if (session == null) {
      return null;
    }

    await _waitForPendingSecuritySync();

    final verdict =
        await SessionSecurityService.instance.validateCurrentSession(
      session: session,
    );
    if (verdict.allowed) {
      return session;
    }

    SecurityEventService.instance.record(
      eventKey: 'auth_revalidation_failed',
      severity: 'high',
      payload: {'reason': verdict.reason},
    );
    SecurityObservabilityService.instance.incrementLocal(
      'auth_channel_kills',
      payload: {'reason': verdict.reason},
    );

    await SessionSecurityService.instance.forceLocalSignOut(
      reason: verdict.reason,
    );
    await _handleInvalidSession(
      redirectToLoginPage: requireSession || _hadAuthenticatedSession,
    );
    return null;
  }

  Future<Session?> _refreshSessionOrRedirect({
    required bool requireSession,
  }) {
    final pendingRefresh = _refreshFuture;
    if (pendingRefresh != null) {
      return pendingRefresh;
    }

    final future = _performRefresh(requireSession: requireSession);
    _refreshFuture = future;

    future.whenComplete(() {
      if (identical(_refreshFuture, future)) {
        _refreshFuture = null;
      }
    });

    return future;
  }

  Future<Session?> _performRefresh({
    required bool requireSession,
  }) async {
    final sessionBeforeRefresh = _client.auth.currentSession;

    try {
      final response = await _client.auth.refreshSession();
      final session = response.session ?? _client.auth.currentSession;

      if (session == null) {
        await _handleInvalidSession(
          redirectToLoginPage: requireSession || _hadAuthenticatedSession,
        );
        return null;
      }

      _hadAuthenticatedSession = true;
      await _syncSecurityState(
        event: AuthChangeEvent.tokenRefreshed,
        session: session,
      );
      return session;
    } on AuthException catch (error) {
      if (_isTransientAuthError(error.message)) {
        unawaited(
          ErrorLogger.logError(
            module: 'session_manager.perform_refresh.auth_exception',
            action: 'transient_auth_error_return_previous_session',
            error: error,
          ),
        );
        return sessionBeforeRefresh;
      }
      unawaited(
        ErrorLogger.logError(
          module: 'session_manager.perform_refresh.auth_exception',
          action: 'invalid_session_redirect',
          error: error,
        ),
      );
      await _handleInvalidSession(
        redirectToLoginPage: requireSession || _hadAuthenticatedSession,
      );
      return null;
    } on PostgrestException catch (error) {
      if (!_isJwtExpiredError(error)) {
        unawaited(
          ErrorLogger.logError(
            module: 'session_manager.perform_refresh.postgrest_exception',
            action: 'rethrow_non_expired',
            error: error,
          ),
        );
        rethrow;
      }

      unawaited(
        ErrorLogger.logError(
          module: 'session_manager.perform_refresh.postgrest_exception',
          action: 'invalid_session_redirect',
          error: error,
        ),
      );
      await _handleInvalidSession(
        redirectToLoginPage: requireSession || _hadAuthenticatedSession,
      );
      return null;
    }
  }

  Future<void> _handleInvalidSession({
    required bool redirectToLoginPage,
  }) async {
    _hadAuthenticatedSession = false;
    SecurityObservabilityService.instance.incrementLocal(
      'auth_channel_kills',
      payload: {'redirect_to_login': redirectToLoginPage},
    );

    if (redirectToLoginPage) {
      await redirectToLogin();
    }
  }

  bool _shouldRefreshSession(Session session) {
    final expiresAt = session.expiresAt;
    if (expiresAt == null) {
      return session.isExpired;
    }

    final nowSeconds = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
    return expiresAt <= nowSeconds + 60;
  }

  bool _isJwtExpiredError(PostgrestException error) {
    final message = error.message.toLowerCase();
    return error.code == 'PGRST303' || _isSessionExpiredMessage(message);
  }

  bool _isSessionExpiredMessage(String message) {
    final normalized = message.toLowerCase();
    return normalized.contains('jwt expired') ||
        normalized.contains('token has expired') ||
        normalized.contains('token expired') ||
        normalized.contains('invalidjwttoken') ||
        normalized.contains('session expired') ||
        normalized.contains('refresh token') ||
        normalized.contains('invalid jwt');
  }

  bool _isTransientAuthError(String message) {
    final normalized = message.toLowerCase();
    return normalized.contains('network') ||
        normalized.contains('socket') ||
        normalized.contains('timed out') ||
        normalized.contains('timeout') ||
        normalized.contains('failed host lookup') ||
        normalized.contains('connection') ||
        normalized.contains('fetch') ||
        normalized.contains('temporarily unavailable') ||
        normalized.contains('try again later') ||
        normalized.contains('status code 429') ||
        normalized.contains('status code 500') ||
        normalized.contains('status code 503');
  }

  Future<void> _syncSecurityState({
    required AuthChangeEvent event,
    required Session? session,
  }) {
    final future = SessionSecurityService.instance.recordAuthState(
      event: event,
      session: session,
    );
    _pendingSecuritySync = future;
    future.whenComplete(() {
      if (identical(_pendingSecuritySync, future)) {
        _pendingSecuritySync = null;
      }
    });
    return future;
  }

  Future<void> _waitForPendingSecuritySync() async {
    final pending = _pendingSecuritySync;
    if (pending == null) {
      return;
    }
    try {
      await pending;
    } catch (_) {}
  }
}

class AuthGuard extends StatefulWidget {
  final Widget child;
  final Widget? loading;

  const AuthGuard({
    super.key,
    required this.child,
    this.loading,
  });

  @override
  State<AuthGuard> createState() => _AuthGuardState();
}

class _AuthGuardState extends State<AuthGuard> {
  late Future<Session?> _sessionFuture;

  @override
  void initState() {
    super.initState();
    _sessionFuture = SessionManager.instance.ensureValidSession(
      requireSession: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Session?>(
      future: _sessionFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return widget.loading ??
              const Scaffold(
                body: Center(child: CircularProgressIndicator()),
              );
        }

        if (snapshot.data == null) {
          return const SizedBox.shrink();
        }

        return widget.child;
      },
    );
  }
}
