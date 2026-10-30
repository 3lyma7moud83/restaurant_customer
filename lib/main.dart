import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/config/mapbox_setup.dart';
import 'core/localization/app_localizations.dart';
import 'core/localization/locale_controller.dart';
import 'core/config/env.dart';
import 'core/services/error_logger.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/theme_controller.dart';
import 'core/ui/web_startup_splash.dart';
import 'core/ui/app_motion.dart';
import 'cart/cart_provider.dart';
import 'pages/home_page.dart';
import 'pages/splash_video_screen.dart';
import 'services/notifications/app_notification_service.dart';
import 'services/session_manager.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _bootstrapLog('Widgets binding initialized.');
  _configureGlobalErrorHandling();
  _bootstrapLog('Global error handling configured.');

  // Paint immediately while the existing bootstrap restores the session.
  // The splash covers the destination; it never replaces its Navigator route.
  runApp(SplashVideoScreen<_StartupConfiguration>(
    initialization: _prepareStartup(),
    destinationBuilder: (context, startup) => CustomerApp(
      bootstrapResult: startup.result,
      initialThemeMode: startup.themeMode,
    ),
    errorBuilder: (context, error, stack) => const CustomerApp(
      bootstrapResult: BootstrapResult.fail('app.bootstrap_env_error'),
    ),
  ));
  _bootstrapLog('runApp executed.');
}

Future<_StartupConfiguration> _prepareStartup() async {
  final bootstrapResult = await _bootstrap();
  final initialThemeMode = await ThemeController.loadInitialMode();
  _bootstrapLog(
    'Bootstrap completed. ok=${bootstrapResult.ok}, '
    'message=${bootstrapResult.message ?? 'none'}.',
  );
  return _StartupConfiguration(bootstrapResult, initialThemeMode);
}

class _StartupConfiguration {
  const _StartupConfiguration(this.result, this.themeMode);

  final BootstrapResult result;
  final ThemeMode themeMode;
}

class CustomerApp extends StatefulWidget {
  const CustomerApp({
    super.key,
    required this.bootstrapResult,
    this.initialThemeMode = ThemeMode.light,
  });

  final BootstrapResult bootstrapResult;
  final ThemeMode initialThemeMode;

  @override
  State<CustomerApp> createState() => _CustomerAppState();
}

class _CustomerAppState extends State<CustomerApp> {
  late final LocaleController _localeController = LocaleController();
  late final ThemeController _themeController = ThemeController(
    initialMode: widget.initialThemeMode,
  );

  @override
  void initState() {
    super.initState();
    unawaited(_localeController.initialize());
    // FCM can deliver an initial-message tap before MaterialApp has created
    // its Navigator. Release the notification service's pending tap queue only
    // after that first frame, so startup/auth restoration cannot discard the
    // intended order route.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // The HTML splash overlay is above Flutter's surface. Signal only after
      // Flutter has rendered its first frame so a successful bootstrap cannot
      // leave a black document-level overlay over the running application.
      // This is a no-op on non-web platforms via the conditional export.
      notifyWebStartupSplashReady();

      if (!mounted || !widget.bootstrapResult.ok) {
        return;
      }
      AppNotificationService.instance.markUiReadyForNotificationNavigation();
    });
  }

  @override
  void dispose() {
    _localeController.dispose();
    _themeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CartProviderWrapper(
      child: AppThemeScope(
        controller: _themeController,
        child: AppLocaleScope(
          controller: _localeController,
          child: AnimatedBuilder(
            animation: Listenable.merge([_localeController, _themeController]),
            builder: (context, _) {
              return MaterialApp(
                navigatorKey: SessionManager.navigatorKey,
                scaffoldMessengerKey: ErrorLogger.scaffoldMessengerKey,
                debugShowCheckedModeBanner: false,
                title: 'delivery-mat3mk',
                theme: AppTheme.light(),
                darkTheme: AppTheme.dark(),
                themeMode: _themeController.themeMode,
                themeAnimationStyle: AppMotion.overlayStyle(context),
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

void _configureGlobalErrorHandling() {
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    unawaited(
      ErrorLogger.logError(
        module: 'main.flutter_error',
        error: details.exception,
        stack: details.stack,
      ),
    );
    ErrorLogger.showUserMessage();
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    unawaited(
      ErrorLogger.logError(
        module: 'main.platform_dispatcher',
        error: error,
        stack: stack,
      ),
    );
    ErrorLogger.showUserMessage();
    return true;
  };
}

Future<BootstrapResult> _bootstrap() async {
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
        publishableKey: AppEnv.supabaseAnonKey,
        authOptions: const FlutterAuthClientOptions(
          autoRefreshToken: true,
          detectSessionInUri: true,
        ),
      );
      _bootstrapLog('Supabase initialized.');
    } else {
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
  } catch (error, stack) {
    _bootstrapLog('Session manager initialization failed: $error');
    await ErrorLogger.logError(
      module: 'bootstrap.session_manager.initialize',
      error: error,
      stack: stack,
    );
    return const BootstrapResult.fail('app.bootstrap_session_error');
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
