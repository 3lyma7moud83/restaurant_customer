import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'error_service.dart';

class GlobalErrorHandler {
  GlobalErrorHandler._();

  static bool _configured = false;

  static Future<void> run({
    required Future<void> Function() appRunner,
    required String appName,
  }) async {
    await ErrorService.instance.initialize(appName: appName);
    _configureGlobalHooks();

    await runZonedGuarded(
      () async {
        await appRunner();
      },
      (error, stack) {
        unawaited(
          ErrorService.instance.capture(
            error: error,
            stackTrace: stack,
            module: 'global_error_handler.run_zoned_guarded',
            showUserMessage: true,
          ),
        );
      },
    );
  }

  static void _configureGlobalHooks() {
    if (_configured) {
      return;
    }
    _configured = true;

    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      unawaited(
        ErrorService.instance.capture(
          error: details.exception,
          stackTrace: details.stack,
          module: 'global_error_handler.flutter_error',
          showUserMessage: true,
        ),
      );
    };

    PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
      unawaited(
        ErrorService.instance.capture(
          error: error,
          stackTrace: stack,
          module: 'global_error_handler.platform_dispatcher',
          showUserMessage: true,
        ),
      );
      return true;
    };

    ErrorWidget.builder = (FlutterErrorDetails details) {
      unawaited(
        ErrorService.instance.capture(
          error: details.exception,
          stackTrace: details.stack,
          module: 'global_error_handler.error_widget',
          showUserMessage: false,
        ),
      );
      return Material(
        color: Colors.white,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              kReleaseMode
                  ? 'حدث خطأ أثناء عرض الشاشة.'
                  : 'Rendering error: ${details.exceptionAsString()}',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    };
  }
}
