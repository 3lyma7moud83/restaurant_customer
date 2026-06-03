import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../theme/app_theme.dart';
import '../ui/input_focus_guard.dart';
import 'app_error.dart';

class ErrorUi {
  ErrorUi._();

  static final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey =
      GlobalKey<ScaffoldMessengerState>();

  static DateTime? _lastSnackAt;

  static void showSnackBar({
    required String message,
    String? code,
    Duration duration = const Duration(seconds: 4),
  }) {
    final messenger = scaffoldMessengerKey.currentState;
    if (messenger == null) {
      return;
    }

    final now = DateTime.now();
    final lastSnackAt = _lastSnackAt;
    if (lastSnackAt != null &&
        now.difference(lastSnackAt) < const Duration(milliseconds: 1200)) {
      return;
    }
    _lastSnackAt = now;

    final content = code == null || code.isEmpty ? message : '$message ($code)';

    void showNow() {
      InputFocusGuard.dismiss();
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(content),
            duration: duration,
          ),
        );
    }

    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.idle ||
        phase == SchedulerPhase.postFrameCallbacks) {
      showNow();
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => showNow());
  }

  static Future<void> showErrorDialog(
    BuildContext context, {
    required String message,
    String? code,
    VoidCallback? onRetry,
  }) async {
    if (!context.mounted) {
      return;
    }

    await showDialog<void>(
      context: context,
      builder: (context) {
        final text =
            code == null || code.isEmpty ? message : '$message\n\n($code)';
        return AlertDialog(
          title: const Text('تنبيه'),
          content: Text(text),
          actions: [
            if (onRetry != null)
              TextButton(
                onPressed: () {
                  Navigator.of(context).pop();
                  onRetry();
                },
                child: const Text('إعادة المحاولة'),
              ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('حسنًا'),
            ),
          ],
        );
      },
    );
  }
}

class CriticalErrorScreen extends StatelessWidget {
  const CriticalErrorScreen({
    super.key,
    required this.error,
    this.onRetry,
  });

  final AppError error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.error_outline_rounded,
                  color: Colors.redAccent,
                  size: 52,
                ),
                const SizedBox(height: 14),
                Text(
                  error.userMessage,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'رمز الخطأ: ${error.code}',
                  style: const TextStyle(
                    color: AppTheme.textMuted,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (onRetry != null) ...[
                  const SizedBox(height: 18),
                  ElevatedButton(
                    onPressed: onRetry,
                    child: const Text('إعادة المحاولة'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class ErrorRetryWidget extends StatelessWidget {
  const ErrorRetryWidget({
    super.key,
    required this.message,
    required this.onRetry,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppTheme.textMuted,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: onRetry,
              child: const Text('إعادة المحاولة'),
            ),
          ],
        ),
      ),
    );
  }
}

class NoInternetWidget extends StatelessWidget {
  const NoInternetWidget({
    super.key,
    this.onRetry,
    this.message = 'لا يوجد اتصال بالإنترنت. تحقق من الشبكة ثم حاول مرة أخرى.',
  });

  final VoidCallback? onRetry;
  final String message;

  @override
  Widget build(BuildContext context) {
    return ErrorRetryWidget(
      message: message,
      onRetry: onRetry ?? () {},
    );
  }
}
