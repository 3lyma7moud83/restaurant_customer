import 'package:flutter/material.dart';

enum AppBreakpoint {
  mobile,
  tablet,
  desktop,
}

class AppResponsive {
  AppResponsive._();

  static AppBreakpoint breakpointOf(double width) {
    if (width >= 1024) {
      return AppBreakpoint.desktop;
    }
    if (width >= 700) {
      return AppBreakpoint.tablet;
    }
    return AppBreakpoint.mobile;
  }

  static double maxContentWidth(double width) {
    if (width >= 1600) {
      return 1360;
    }
    if (width >= 1200) {
      return 1180;
    }
    if (width >= 1024) {
      return 1040;
    }
    return width;
  }

  static EdgeInsets pagePadding(double width) {
    final horizontal = (width * 0.042).clamp(12.0, 28.0).toDouble();
    final top = (width * 0.026).clamp(14.0, 22.0).toDouble();
    final bottom = (width * 0.034).clamp(14.0, 24.0).toDouble();
    return EdgeInsets.fromLTRB(horizontal, top, horizontal, bottom);
  }
}

class AppConstrainedContent extends StatelessWidget {
  const AppConstrainedContent({
    super.key,
    required this.child,
    this.padding,
    this.alignment = Alignment.topCenter,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return Align(
          alignment: alignment,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: AppResponsive.maxContentWidth(width),
            ),
            child: Padding(
              padding: padding ?? AppResponsive.pagePadding(width),
              child: child,
            ),
          ),
        );
      },
    );
  }
}
