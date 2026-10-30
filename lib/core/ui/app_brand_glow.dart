import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The existing cart's soft orange backlight, shared with the Home wordmark.
/// Paints around its child's bounds without changing layout or running a ticker.
class AppBrandGlow extends StatelessWidget {
  const AppBrandGlow({super.key, required this.child});

  final Widget child;

  static List<BoxShadow> get shadows => [
        BoxShadow(
          color: AppTheme.primary.withValues(alpha: 0.10),
          blurRadius: 14,
          offset: const Offset(0, 8),
        ),
        const BoxShadow(
          color: Color(0x10000000),
          blurRadius: 9,
          offset: Offset(0, 5),
        ),
      ];

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          gradient: RadialGradient(
            radius: 1,
            colors: [
              AppTheme.primary.withValues(alpha: 0.10),
              AppTheme.primary.withValues(alpha: 0),
            ],
          ),
          boxShadow: shadows,
        ),
        child: child,
      );
}
