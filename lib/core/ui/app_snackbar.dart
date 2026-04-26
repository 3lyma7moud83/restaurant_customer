import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'input_focus_guard.dart';

class AppSnackBar {
  AppSnackBar._();

  static void show(
    BuildContext context, {
    required String message,
    Duration? duration,
    SnackBarAction? action,
    bool clearCurrent = true,
  }) {
    if (!context.mounted) {
      return;
    }

    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) {
      return;
    }

    final wrappedAction = action == null
        ? null
        : SnackBarAction(
            label: action.label,
            textColor: action.textColor,
            disabledTextColor: action.disabledTextColor,
            backgroundColor: action.backgroundColor,
            disabledBackgroundColor: action.disabledBackgroundColor,
            onPressed: () {
              InputFocusGuard.dismiss(context: context);
              action.onPressed();
            },
          );

    void showNow() {
      if (!context.mounted) {
        return;
      }
      InputFocusGuard.dismiss(context: context);
      if (clearCurrent) {
        messenger.hideCurrentSnackBar();
      }
      messenger.showSnackBar(
        SnackBar(
          content: Text(message),
          duration: duration ?? const Duration(seconds: 4),
          action: wrappedAction,
        ),
      );
    }

    final phase = SchedulerBinding.instance.schedulerPhase;
    final canShowNow = phase == SchedulerPhase.idle ||
        phase == SchedulerPhase.postFrameCallbacks;
    if (canShowNow) {
      showNow();
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => showNow());
  }
}
