import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/auth/oauth_callback_cleaner.dart';
import 'core/config/mapbox_setup.dart';
import 'core/errors/global_error_handler.dart';
import 'core/localization/app_localizations.dart';
import 'core/localization/locale_controller.dart';
import 'core/stability/analytics_integrity_service.dart';
import 'core/stability/checkout_guard_service.dart';
import 'core/stability/notification_dedupe_service.dart';
import 'core/stability/offline_order_queue_service.dart';
import 'core/stability/payment_reconciliation_service.dart';
import 'core/stability/realtime_presence_service.dart';
import 'core/stability/rpc_security_service.dart';
import 'core/stability/security_event_service.dart';
import 'core/stability/security_observability_service.dart';
import 'core/stability/session_security_service.dart';
import 'core/stability/stability_metrics_service.dart';
import 'core/config/env.dart';
import 'core/services/error_logger.dart';
import 'core/theme/app_theme.dart';
import 'cart/cart_provider.dart';
import 'pages/home_page.dart';
import 'services/notifications/app_notification_service.dart';
import 'services/session_manager.dart';

Future<void> main() async {
  await GlobalErrorHandler.run(
    appName: ErrorLogger.appName,
    appRunner: () async {
      WidgetsFlutterBinding.ensureInitialized();
      _bootstrapLog('Widgets binding initialized.');
      final bootstrapResult = await _bootstrap();
      _bootstrapLog(
        'Bootstrap completed. ok=${bootstrapResult.ok}, '
        'message=${bootstrapResult.message ?? 'none'}.',
      );
      runApp(CustomerApp(bootstrapResult: bootstrapResult));
      _bootstrapLog('runApp executed.');
    },
  );
}

class CustomerApp extends StatefulWidget {
  const CustomerApp({
    super.key,
    required this.bootstrapResult,
  });

  final BootstrapResult bootstrapResult;

  @override
  State<CustomerApp> createState() => _CustomerAppState();
}

class _CustomerAppState extends State<CustomerApp> {
  late final LocaleController _localeController = LocaleController();
  late final WidgetsBindingObserver _lifecycleObserver;

  @override
  void initState() {
    super.initState();
    _lifecycleObserver = _AppLifecycleObserver(
      onResumed: () {
        unawaited(_runStabilityRecoveryCycle());
      },
    );
    WidgetsBinding.instance.addObserver(_lifecycleObserver);
    unawaited(_localeController.initialize());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(_lifecycleObserver);
    unawaited(PaymentReconciliationService.instance.dispose());
    unawaited(OfflineOrderQueueService.instance.dispose());
    unawaited(AnalyticsIntegrityService.instance.dispose());
    unawaited(RealtimePresenceService.instance.dispose());
    unawaited(SecurityObservabilityService.instance.dispose());
    unawaited(StabilityMetricsService.instance.dispose());
    _localeController.dispose();
    super.dispose();
  }

  Future<void> _runStabilityRecoveryCycle() async {
    await CheckoutGuardService.instance.clearStalePendingState();
    await SessionManager.instance.ensureValidSession(requireSession: false);
    await PaymentReconciliationService.instance.reconcilePendingPayments(
      trigger: 'app_resumed',
    );
    await OfflineOrderQueueService.instance.flush();
    await AnalyticsIntegrityService.instance.flush();
    await SecurityEventService.instance.flush();
    await SecurityObservabilityService.instance.refreshRemoteSnapshot();
  }

  @override
  Widget build(BuildContext context) {
    return CartProviderWrapper(
      child: AppLocaleScope(
        controller: _localeController,
        child: AnimatedBuilder(
          animation: _localeController,
          builder: (context, _) {
            return MaterialApp(
              navigatorKey: SessionManager.navigatorKey,
              scaffoldMessengerKey: ErrorLogger.scaffoldMessengerKey,
              debugShowCheckedModeBanner: false,
              title: 'Delivery Mat3mk',
              theme: AppTheme.light(),
              scrollBehavior: const _AppScrollBehavior(),
              locale: _localeController.locale,
              supportedLocales: AppLocalizations.supportedLocales,
              localizationsDelegates: const [
                AppLocalizations.delegate,
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              home: widget.bootstrapResult.ok
                  ? const _SessionGate()
                  : _BootstrapErrorScreen(
                      messageKey: widget.bootstrapResult.message ??
                          ErrorLogger.userMessage,
                    ),
            );
          },
        ),
      ),
    );
  }
}

class BootstrapResult {
  const BootstrapResult._({
    required this.ok,
    this.message,
  });

  final bool ok;
  final String? message;

  const BootstrapResult.ok() : this._(ok: true);
  const BootstrapResult.fail(String message)
      : this._(ok: false, message: message);
}

Future<BootstrapResult> _bootstrap() async {
  await ErrorLogger.initialize();
  _bootstrapLog('Loading environment assets...');
  try {
    await AppEnv.load();
    _bootstrapLog(
      'Environment loaded from ${AppEnv.loadedFile} '
      '(APP_ENV=${AppEnv.environment}).',
    );
  } catch (error, stack) {
    _bootstrapLog('Environment load failed: $error');
    await ErrorLogger.logError(
      module: 'bootstrap.app_env.load',
      error: error,
      stack: stack,
    );
    return const BootstrapResult.fail('app.bootstrap_env_error');
  }

  _bootstrapLog('Configuring map provider...');
  try {
    final configured = await configureMapboxAccessToken(AppEnv.mapboxToken);
    if (configured) {
      _bootstrapLog('Mapbox native token configured.');
    } else {
      _bootstrapLog('Mapbox native SDK skipped on this platform.');
    }
  } catch (error, stack) {
    _bootstrapLog('Mapbox token setup failed: $error');
    await ErrorLogger.logError(
      module: 'bootstrap.mapbox.setAccessToken',
      error: error,
      stack: stack,
    );
  }

  _bootstrapLog('Initializing Supabase...');
  try {
    if (!_isSupabaseInitialized()) {
      await Supabase.initialize(
        url: AppEnv.supabaseUrl,
        anonKey: AppEnv.supabaseAnonKey,
        authOptions: const FlutterAuthClientOptions(
          autoRefreshToken: true,
          detectSessionInUri: true,
        ),
      );
      clearOAuthCallbackParameters();
      _bootstrapLog('Supabase initialized.');
    } else {
      clearOAuthCallbackParameters();
      _bootstrapLog('Supabase already initialized.');
    }
  } catch (error, stack) {
    _bootstrapLog('Supabase initialization failed: $error');
    await ErrorLogger.logError(
      module: 'bootstrap.supabase.initialize',
      error: error,
      stack: stack,
    );
    return const BootstrapResult.fail('app.bootstrap_supabase_error');
  }

  _bootstrapLog('Initializing session manager...');
  try {
    await SessionManager.instance.initialize();
    _bootstrapLog('Session manager initialized.');
    await SessionManager.instance.ensureValidSession(requireSession: false);
    _bootstrapLog('Session recovery completed.');
  } catch (error, stack) {
    _bootstrapLog('Session manager initialization failed: $error');
    await ErrorLogger.logError(
      module: 'bootstrap.session_manager.initialize',
      error: error,
      stack: stack,
    );
    return const BootstrapResult.fail('app.bootstrap_session_error');
  }

  _bootstrapLog('Initializing stability layers...');
  try {
    await StabilityMetricsService.instance.initialize();
    await CheckoutGuardService.instance.initialize();
    await PaymentReconciliationService.instance.initialize();
    await AnalyticsIntegrityService.instance.initialize();
    await NotificationDedupeService.instance.initialize();
    await SessionSecurityService.instance.initialize();
    await RealtimePresenceService.instance.initialize();
    await RpcSecurityService.instance.initialize();
    await SecurityEventService.instance.initialize();
    await SecurityObservabilityService.instance.initialize();
    _bootstrapLog('Stability layers initialized.');
  } catch (error, stack) {
    _bootstrapLog('Stability layers initialization failed: $error');
    await ErrorLogger.logError(
      module: 'bootstrap.stability.initialize',
      error: error,
      stack: stack,
    );
  }

  _bootstrapLog('Initializing notifications...');
  try {
    await AppNotificationService.instance.initialize();
    _bootstrapLog('Notification service initialized.');
  } catch (error, stack) {
    _bootstrapLog('Notification service initialization failed: $error');
    await ErrorLogger.logError(
      module: 'bootstrap.notification_service.initialize',
      error: error,
      stack: stack,
    );
  }

  return const BootstrapResult.ok();
}

bool _isSupabaseInitialized() {
  try {
    Supabase.instance.client;
    return true;
  } catch (_) {
    return false;
  }
}

void _bootstrapLog(String message) {
  debugPrint('[bootstrap] $message');
}

class _BootstrapErrorScreen extends StatelessWidget {
  const _BootstrapErrorScreen({
    required this.messageKey,
  });

  final String messageKey;

  @override
  Widget build(BuildContext context) {
    final resolvedMessage =
        messageKey.startsWith('app.') ? context.tr(messageKey) : messageKey;
    return Scaffold(
      appBar: AppBar(title: Text(context.tr('app.bootstrap_failed_title'))),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          resolvedMessage,
          style: const TextStyle(fontSize: 15),
        ),
      ),
    );
  }
}

class _SessionGate extends StatelessWidget {
  const _SessionGate();

  @override
  Widget build(BuildContext context) {
    final client = Supabase.instance.client;

    return StreamBuilder<AuthState>(
      stream: client.auth.onAuthStateChange,
      builder: (context, _) => const HomePage(),
    );
  }
}

class _AppScrollBehavior extends MaterialScrollBehavior {
  const _AppScrollBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) {
    return AppTheme.bouncingScrollPhysics;
  }

  @override
  Set<PointerDeviceKind> get dragDevices => const {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.stylus,
        PointerDeviceKind.invertedStylus,
        PointerDeviceKind.unknown,
      };

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return child;
  }
}

class _AppLifecycleObserver extends WidgetsBindingObserver {
  _AppLifecycleObserver({
    required this.onResumed,
  });

  final VoidCallback onResumed;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      onResumed();
    }
  }
}
