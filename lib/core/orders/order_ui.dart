import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'order_status_utils.dart';
import '../theme/app_theme.dart';

String formatOrderDate(DateTime date) {
  final local = date.toLocal();
  final day = local.day.toString().padLeft(2, '0');
  final month = local.month.toString().padLeft(2, '0');
  final year = local.year.toString();

  var hour = local.hour;
  final minute = local.minute.toString().padLeft(2, '0');
  final period = hour >= 12 ? 'م' : 'ص';
  hour = hour % 12;
  if (hour == 0) {
    hour = 12;
  }

  return '$day/$month/$year - ${hour.toString().padLeft(2, '0')}:$minute $period';
}

String formatPrice(double value) {
  final normalized =
      value % 1 == 0 ? value.toStringAsFixed(0) : value.toStringAsFixed(2);
  return '$normalized ج';
}

class OrderStatusBadge extends StatelessWidget {
  const OrderStatusBadge({
    super.key,
    required this.info,
    this.fontSize = 12,
    this.padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
  });

  final OrderStatusInfo info;
  final double fontSize;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: info.color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(info.icon, size: fontSize + 2, color: info.color),
          const SizedBox(width: 6),
          Text(
            info.text,
            style: TextStyle(
              color: info.color,
              fontWeight: FontWeight.w700,
              fontSize: fontSize,
            ),
          ),
        ],
      ),
    );
  }
}

class OrderSectionCard extends StatefulWidget {
  const OrderSectionCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
  });

  final Widget child;
  final EdgeInsets padding;

  @override
  State<OrderSectionCard> createState() => _OrderSectionCardState();
}

class _OrderSectionCardState extends State<OrderSectionCard> {
  bool _hovered = false;

  void _setHovered(bool value) {
    if (!mounted || _hovered == value) {
      return;
    }
    setState(() => _hovered = value);
  }

  @override
  Widget build(BuildContext context) {
    final animationDuration =
        kIsWeb ? Duration.zero : AppTheme.sectionTransitionDuration;
    final shadowColor =
        _hovered ? const Color(0x18000000) : const Color(0x10000000);

    return MouseRegion(
      onEnter: (_) => _setHovered(true),
      onExit: (_) => _setHovered(false),
      child: AnimatedContainer(
        duration: animationDuration,
        curve: AppTheme.emphasizedCurve,
        padding: widget.padding,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: AppTheme.border.withValues(alpha: _hovered ? 0.95 : 0.75),
          ),
          boxShadow: [
            BoxShadow(
              color: shadowColor,
              blurRadius: _hovered ? 28 : 22,
              offset: Offset(0, _hovered ? 16 : 12),
            ),
          ],
        ),
        child: widget.child,
      ),
    );
  }
}

class ScaleOnTap extends StatefulWidget {
  const ScaleOnTap({
    super.key,
    required this.child,
    this.onTap,
    this.scale = 0.97,
  });

  final Widget child;
  final VoidCallback? onTap;
  final double scale;

  @override
  State<ScaleOnTap> createState() => _ScaleOnTapState();
}

class _ScaleOnTapState extends State<ScaleOnTap> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (!mounted || _pressed == value) {
      return;
    }
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final animationDuration =
        kIsWeb ? Duration.zero : AppTheme.microInteractionDuration;
    return MouseRegion(
      cursor:
          widget.onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTapDown: widget.onTap == null ? null : (_) => _setPressed(true),
        onTapUp: widget.onTap == null ? null : (_) => _setPressed(false),
        onTapCancel: widget.onTap == null ? null : () => _setPressed(false),
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _pressed ? widget.scale : 1,
          duration: animationDuration,
          curve: AppTheme.emphasizedCurve,
          child: AnimatedOpacity(
            opacity: _pressed ? 0.94 : 1,
            duration: animationDuration,
            curve: AppTheme.emphasizedCurve,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
