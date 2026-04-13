import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/config/env.dart';
import 'core/services/error_logger.dart';
import 'core/theme/app_theme.dart';
import 'cart/cart_provider.dart';
import 'pages/home_page.dart';
import 'services/notifications/app_notification_service.dart';
import 'services/session_manager.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _configureGlobalErrorHandling();

  final bootstrapResult = await _bootstrap();
  runApp(CustomerApp(bootstrapResult: bootstrapResult));
}

class CustomerApp extends StatelessWidget {
  const CustomerApp({
    super.key,
    required this.bootstrapResult,
  });

  final BootstrapResult bootstrapResult;

  @override
  Widget build(BuildContext context) {
    return CartProviderWrapper(
      child: MaterialApp(
        navigatorKey: SessionManager.navigatorKey,
        scaffoldMessengerKey: ErrorLogger.scaffoldMessengerKey,
        debugShowCheckedModeBanner: false,
        title: 'Delivery',
        theme: AppTheme.light(),
        scrollBehavior: const _AppScrollBehavior(),
        home: bootstrapResult.ok
            ? const _SessionGate()
            : _BootstrapErrorScreen(
                message: bootstrapResult.message ?? ErrorLogger.userMessage,
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
  try {
    await AppEnv.load();
  } catch (error, stack) {
    await ErrorLogger.logError(
      module: 'bootstrap.app_env.load',
      error: error,
      stack: stack,
    );
    return const BootstrapResult.fail(
      'فشل تحميل إعدادات البيئة. تأكد من APP_ENV وملفات .env المطلوبة.',
    );
  }

  try {
    // Must run before any map objects are created.
    MapboxOptions.setAccessToken(AppEnv.mapboxToken);
  } catch (error, stack) {
    await ErrorLogger.logError(
      module: 'bootstrap.mapbox.setAccessToken',
      error: error,
      stack: stack,
    );
  }

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
    }
  } catch (error, stack) {
    await ErrorLogger.logError(
      module: 'bootstrap.supabase.initialize',
      error: error,
      stack: stack,
    );
    return const BootstrapResult.fail(
      'فشل تهيئة Supabase. تأكد من مفاتيح البيئة واتصال الإنترنت.',
    );
  }

  try {
    await SessionManager.instance.initialize();
  } catch (error, stack) {
    await ErrorLogger.logError(
      module: 'bootstrap.session_manager.initialize',
      error: error,
      stack: stack,
    );
    return const BootstrapResult.fail(
      'فشل تهيئة الجلسة. حاول تشغيل التطبيق مرة أخرى.',
    );
  }

  try {
    await AppNotificationService.instance.initialize();
  } catch (error, stack) {
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

class _BootstrapErrorScreen extends StatelessWidget {
  const _BootstrapErrorScreen({
    required this.message,
  });

  final String message;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('تعذر تشغيل التطبيق')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          message,
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
