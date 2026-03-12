import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/config/env.dart';
import 'core/services/error_logger.dart';
import 'core/theme/app_theme.dart';
import 'pages/home_page.dart';
import 'cart/cart_provider.dart';
import 'services/session_manager.dart';

Future<void> main() async {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();

    await dotenv.load(fileName: '.env');
    MapboxOptions.setAccessToken(AppEnv.mapboxToken);

    await Supabase.initialize(
      url: AppEnv.supabaseUrl,
      anonKey: AppEnv.supabaseAnonKey,
      authOptions: const FlutterAuthClientOptions(
        autoRefreshToken: true,
        detectSessionInUri: true,
      ),
    );

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

    await SessionManager.instance.initialize();

    runApp(const CustomerApp());
  }, (error, stack) {
    unawaited(
      ErrorLogger.logError(
        module: 'main.run_zoned_guarded',
        error: error,
        stack: stack,
      ),
    );

    ErrorLogger.showUserMessage();
  });
}

class CustomerApp extends StatelessWidget {
  const CustomerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return CartProviderWrapper(
      child: MaterialApp(
        navigatorKey: SessionManager.navigatorKey,
        scaffoldMessengerKey: ErrorLogger.scaffoldMessengerKey,
        debugShowCheckedModeBanner: false,
        title: 'Delivery',
        theme: AppTheme.light(),
        home: const HomePage(),
      ),
    );
  }
}
