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
  Duration get reverseTransitionDuration =>
      _duration(AppMotion.contentDuration);

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
  Duration get reverseTransitionDuration => AppMotion.contentDuration;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (AppMotion.reduceMotion(context) || route.isFirst) return child;
    final motion =
        route is AppPageRoute<T> ? route.motion : AppRouteMotion.standard;
    final progress = animation.drive(CurveTween(curve: AppMotion.curve));
    final content = motion == AppRouteMotion.detail
        ? ScaleTransition(
            scale: progress.drive(Tween<double>(begin: 0.985, end: 1)),
            child: child,
          )
        : child;
    // Flutter owns/disposes the gesture controller and mirrors the slide in RTL.
    // Keeping its gesture wrapper also preserves cancellation and PopScope.
    return CupertinoRouteTransitionMixin.buildPageTransitions<T>(
      route,
      context,
      animation,
      secondaryAnimation,
      FadeTransition(
        opacity: animation.drive(
          Tween<double>(
                  begin: motion == AppRouteMotion.checkout ? 0.86 : 0.94,
                  end: 1)
              .chain(
            CurveTween(curve: AppMotion.curve),
          ),
        ),
        child: content,
      ),
    );
  }
}
