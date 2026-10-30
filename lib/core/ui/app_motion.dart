import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

enum AppRouteMotion { standard, detail, checkout }

/// Shared timings for presentation only; never schedules navigation or data work.
abstract final class AppMotion {
  static const microDuration = Duration(milliseconds: 140);
  static const contentDuration = Duration(milliseconds: 220);
  static const pageDuration = Duration(milliseconds: 260);
  static const detailDuration = Duration(milliseconds: 300);
  static const checkoutDuration = Duration(milliseconds: 280);
  static const curve = Curves.easeOutCubic;

  static bool reduceMotion(BuildContext context) =>
      MediaQuery.maybeDisableAnimationsOf(context) ??
      WidgetsBinding
          .instance.platformDispatcher.accessibilityFeatures.disableAnimations;

  static Duration duration(BuildContext context, Duration duration) =>
      reduceMotion(context) ? Duration.zero : duration;

  static AnimationStyle overlayStyle(BuildContext context) =>
      reduceMotion(context)
          ? AnimationStyle.noAnimation
          : const AnimationStyle(
              duration: pageDuration,
              reverseDuration: contentDuration,
              curve: curve,
              reverseCurve: Curves.easeInCubic,
            );

  static const pageTransitionsTheme = PageTransitionsTheme(
    builders: {
      TargetPlatform.android: AppPageTransitionsBuilder(),
      TargetPlatform.iOS: AppPageTransitionsBuilder(),
      TargetPlatform.macOS: AppPageTransitionsBuilder(),
      TargetPlatform.windows: AppPageTransitionsBuilder(),
      TargetPlatform.linux: AppPageTransitionsBuilder(),
      TargetPlatform.fuchsia: AppPageTransitionsBuilder(),
    },
  );
}

/// Retains Cupertino's existing interactive back gesture, route result and state.
/// All entry points, including notification navigation, keep using AppTheme's
/// route factory; no feature needs its own controller or navigation delay.
class AppPageRoute<T> extends CupertinoPageRoute<T> {
  AppPageRoute({
    required super.builder,
    super.settings,
    super.fullscreenDialog,
    this.motion = AppRouteMotion.standard,
  });

  final AppRouteMotion motion;

  Duration _duration(Duration value) {
    final context = navigator?.context;
    return context == null ? value : AppMotion.duration(context, value);
  }

  @override
  Duration get transitionDuration => _duration(switch (motion) {
        AppRouteMotion.standard => AppMotion.pageDuration,
        AppRouteMotion.detail => AppMotion.detailDuration,
        AppRouteMotion.checkout => AppMotion.checkoutDuration,
      });

  @override
  Duration get reverseTransitionDuration => transitionDuration;

  // MaterialApp creates its initial route as MaterialPageRoute. Supplying the
  // same visual delegate keeps that route in sync with subsequent app routes.
  @override
  DelegatedTransitionBuilder get delegatedTransition =>
      AppPageTransitionsBuilder.outgoingTransition;

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) =>
      const AppPageTransitionsBuilder().buildTransitions(
        this,
        context,
        animation,
        secondaryAnimation,
        child,
      );
}

class AppPageTransitionsBuilder extends PageTransitionsBuilder {
  const AppPageTransitionsBuilder();

  @override
  Duration get transitionDuration => AppMotion.pageDuration;

  @override
  Duration get reverseTransitionDuration => AppMotion.pageDuration;

  @override
  DelegatedTransitionBuilder get delegatedTransition => outgoingTransition;

  static Widget outgoingTransition(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    bool allowSnapshotting,
    Widget? child,
  ) {
    if (AppMotion.reduceMotion(context)) {
      return child ?? const SizedBox.shrink();
    }
    return _outgoing(context, secondaryAnimation, child);
  }

  static Widget _outgoing(
      BuildContext context, Animation<double> animation, Widget? child) {
    final progress = animation.drive(CurveTween(curve: Curves.easeInOutCubic));
    return SlideTransition(
      position: progress.drive(
          Tween<Offset>(begin: Offset.zero, end: const Offset(-.025, 0))),
      textDirection: Directionality.of(context),
      transformHitTests: false,
      child: FadeTransition(
        opacity: progress.drive(Tween<double>(begin: 1, end: .92)),
        child: child,
      ),
    );
  }

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (AppMotion.reduceMotion(context)) return child;
    // The initial MaterialApp route already has a completed animation. Do not
    // bypass isFirst: replacement/stack-reset routes can become first while
    // their entrance animation is still running.
    final progress = animation.drive(CurveTween(curve: Curves.easeInOutCubic));
    final content = _outgoing(
      context,
      secondaryAnimation,
      SlideTransition(
        position: progress.drive(
            Tween<Offset>(begin: const Offset(.08, 0), end: Offset.zero)),
        textDirection: Directionality.of(context),
        child: FadeTransition(opacity: progress, child: child),
      ),
    );
    if (route.isFirst) return content;
    // Retain Flutter's back-gesture detector and controller, but neutralize its
    // full-width Cupertino slide. The bounded fade/slide above owns the visuals.
    // It follows the same route animation during a drag, cancellation and pop.
    return CupertinoRouteTransitionMixin.buildPageTransitions<T>(
      route,
      context,
      kAlwaysCompleteAnimation,
      kAlwaysDismissedAnimation,
      content,
    );
  }
}
