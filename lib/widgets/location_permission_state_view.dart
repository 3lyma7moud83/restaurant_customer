import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';
import '../core/ui/app_components.dart';

class LocationPermissionStateView extends StatelessWidget {
  const LocationPermissionStateView({
    super.key,
    required this.icon,
    required this.message,
    required this.buttonLabel,
    required this.onPressed,
    this.loading = false,
  });

  final IconData icon;
  final String message;
  final String buttonLabel;
  final VoidCallback onPressed;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: AppCard(
            padding: const EdgeInsets.fromLTRB(24, 26, 24, 22),
            radius: 30,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Colors.white,
                const Color(0xFFFFF8ED),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 76,
                  height: 76,
                  decoration: BoxDecoration(
                    color: AppTheme.primary.withValues(alpha: 0.14),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    icon,
                    size: 38,
                    color: AppTheme.primaryDeep,
                  ),
                ),
                const SizedBox(height: 18),
                AppText(
                  message,
                  role: AppTextRole.title,
                  align: TextAlign.center,
                  style: const TextStyle(fontSize: 19, height: 1.38),
                ),
                const SizedBox(height: 20),
                AppButton(
                  label: buttonLabel,
                  onPressed: onPressed,
                  loading: loading,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
