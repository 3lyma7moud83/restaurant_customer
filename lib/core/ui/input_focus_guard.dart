import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

class InputFocusGuard {
  InputFocusGuard._();

  static bool get hasActiveFocus {
    return FocusManager.instance.primaryFocus?.hasFocus == true;
  }

  static bool get hasActiveEditableFocus {
    final focusNode = FocusManager.instance.primaryFocus;
    if (focusNode == null || !focusNode.hasFocus) {
      return false;
    }

    final focusContext = focusNode.context;
    if (focusContext == null) {
      return true;
    }
    return focusContext.widget is EditableText;
  }

  static void dismiss({BuildContext? context}) {
    _performDismiss(context: context);

    if (!kIsWeb) {
      return;
    }

    // Web text inputs can linger for a frame; repeat after frame/microtask.
    final scheduler = SchedulerBinding.instance;
    final phase = scheduler.schedulerPhase;
    final insideFrame = phase == SchedulerPhase.transientCallbacks ||
        phase == SchedulerPhase.midFrameMicrotasks ||
        phase == SchedulerPhase.persistentCallbacks;
    if (insideFrame) {
      scheduler.addPostFrameCallback((_) {
        _performDismiss(context: context);
      });
      return;
    }

    scheduleMicrotask(() => _performDismiss(context: context));
  }

  static Future<T?> runWithTransitionGuard<T>({
    BuildContext? context,
    required Future<T?> Function() action,
  }) async {
    await prepareForUiTransition(context: context);
    if (context != null && !context.mounted) {
      return null;
    }
    return action();
  }

  static void _performDismiss({BuildContext? context}) {
    FocusScopeNode? scope;
    if (context != null && context.mounted) {
      try {
        scope = FocusScope.of(context);
      } catch (_) {
        scope = null;
      }
    }

    if (scope != null && scope.hasFocus) {
      scope.unfocus(disposition: UnfocusDisposition.scope);
    }

    FocusManager.instance.primaryFocus?.unfocus(
      disposition: UnfocusDisposition.scope,
    );
  }

  static Future<void> prepareForUiTransition({BuildContext? context}) async {
    dismiss(context: context);
    if (kIsWeb) {
      final scheduler = SchedulerBinding.instance;
      final phase = scheduler.schedulerPhase;
      if (phase != SchedulerPhase.idle) {
        await scheduler.endOfFrame;
      }

      await Future<void>.delayed(Duration.zero);
      dismiss();

      if (scheduler.schedulerPhase != SchedulerPhase.idle) {
        await scheduler.endOfFrame;
      }
      await Future<void>.delayed(const Duration(milliseconds: 8));
      dismiss();
      return;
    }

    final scheduler = SchedulerBinding.instance;
    if (scheduler.schedulerPhase != SchedulerPhase.idle) {
      await scheduler.endOfFrame;
    }
    dismiss();
  }
}
