import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

enum AppTextRole { hero, title, body, caption, label }

enum AppButtonVariant { filled, secondary, ghost }

class AppText extends StatelessWidget {
  const AppText(
    this.data, {
    super.key,
    this.role = AppTextRole.body,
    this.align,
    this.color,
    this.weight,
    this.maxLines,
    this.overflow,
    this.style,
  });

  final String data;
  final AppTextRole role;
  final TextAlign? align;
  final Color? color;
  final FontWeight? weight;
  final int? maxLines;
  final TextOverflow? overflow;
  final TextStyle? style;

  TextStyle _resolveStyle(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final baseStyle = switch (role) {
      AppTextRole.hero => textTheme.headlineSmall?.copyWith(
          fontSize: 30,
          fontWeight: FontWeight.w900,
          height: 1.12,
        ),
      AppTextRole.title => textTheme.titleLarge?.copyWith(
          fontSize: 20,
          fontWeight: FontWeight.w800,
          height: 1.2,
        ),
      AppTextRole.caption => textTheme.bodyMedium?.copyWith(
          fontSize: 13,
          color: AppTheme.textMuted,
          fontWeight: FontWeight.w600,
          height: 1.45,
        ),
      AppTextRole.label => textTheme.labelLarge?.copyWith(
          fontWeight: FontWeight.w800,
          height: 1.2,
        ),
      AppTextRole.body => textTheme.bodyLarge?.copyWith(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          height: 1.5,
        ),
    };

    return (baseStyle ?? const TextStyle()).copyWith(
      color: color,
      fontWeight: weight,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Text(
      data,
      textAlign: align,
      maxLines: maxLines,
      overflow: overflow,
      style: _resolveStyle(context).merge(style),
    );
  }
}

class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(20),
    this.margin,
    this.radius = 28,
    this.backgroundColor,
    this.borderColor,
    this.gradient,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final double radius;
  final Color? backgroundColor;
  final Color? borderColor;
  final Gradient? gradient;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: margin,
      padding: padding,
      decoration: BoxDecoration(
        color: gradient == null ? backgroundColor ?? Colors.white : null,
        gradient: gradient,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: borderColor ?? AppTheme.border.withValues(alpha: 0.85),
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x12000000),
            blurRadius: 28,
            offset: Offset(0, 16),
          ),
        ],
      ),
      child: child,
    );
  }
}

class AppButton extends StatefulWidget {
  const AppButton({
    super.key,
    required this.label,
    this.onPressed,
    this.variant = AppButtonVariant.filled,
    this.icon,
    this.loading = false,
    this.expand = true,
    this.height = 56,
    this.radius = 22,
    this.padding,
  });

  final String label;
  final VoidCallback? onPressed;
  final AppButtonVariant variant;
  final Widget? icon;
  final bool loading;
  final bool expand;
  final double height;
  final double radius;
  final EdgeInsetsGeometry? padding;

  @override
  State<AppButton> createState() => _AppButtonState();
}

class _AppButtonState extends State<AppButton> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (!mounted || _pressed == value) {
      return;
    }
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null && !widget.loading;

    final background = switch (widget.variant) {
      AppButtonVariant.filled =>
        enabled ? AppTheme.primary : AppTheme.primary.withValues(alpha: 0.38),
      AppButtonVariant.secondary =>
        enabled ? Colors.white : Colors.white.withValues(alpha: 0.72),
      AppButtonVariant.ghost => Colors.transparent,
    };

    final foreground = switch (widget.variant) {
      AppButtonVariant.filled => Colors.white,
      AppButtonVariant.secondary => AppTheme.text,
      AppButtonVariant.ghost => enabled ? AppTheme.text : AppTheme.textMuted,
    };

    final borderColor = switch (widget.variant) {
      AppButtonVariant.filled => Colors.transparent,
      AppButtonVariant.secondary => AppTheme.border,
      AppButtonVariant.ghost => Colors.transparent,
    };

    final boxShadow = enabled && widget.variant != AppButtonVariant.ghost
        ? [
            BoxShadow(
              color: widget.variant == AppButtonVariant.filled
                  ? AppTheme.primary.withValues(alpha: 0.24)
                  : const Color(0x12000000),
              blurRadius: widget.variant == AppButtonVariant.filled ? 22 : 18,
              offset: const Offset(0, 12),
            ),
          ]
        : const <BoxShadow>[];

    final content = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.loading)
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2.2,
              color: foreground,
            ),
          )
        else if (widget.icon != null) ...[
          IconTheme(
            data: IconThemeData(color: foreground, size: 18),
            child: widget.icon!,
          ),
          const SizedBox(width: 10),
        ],
        Flexible(
          child: AppText(
            widget.label,
            role: AppTextRole.label,
            color: foreground,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );

    return AnimatedScale(
      scale: _pressed && enabled ? 0.985 : 1,
      duration: kIsWeb ? Duration.zero : AppTheme.microInteractionDuration,
      curve: AppTheme.emphasizedCurve,
      child: SizedBox(
        width: widget.expand ? double.infinity : null,
        height: widget.height,
        child: AnimatedContainer(
          duration: kIsWeb ? Duration.zero : AppTheme.microInteractionDuration,
          curve: AppTheme.emphasizedCurve,
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(widget.radius),
            border: Border.all(color: borderColor),
            boxShadow: boxShadow,
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: enabled ? widget.onPressed : null,
              onTapDown: enabled ? (_) => _setPressed(true) : null,
              onTapUp: enabled ? (_) => _setPressed(false) : null,
              onTapCancel: enabled ? () => _setPressed(false) : null,
              borderRadius: BorderRadius.circular(widget.radius),
              child: Padding(
                padding: widget.padding ??
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                child: Center(child: content),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class AppInput extends StatefulWidget {
  const AppInput({
    super.key,
    required this.controller,
    this.focusNode,
    this.label,
    this.hint,
    this.prefixIcon,
    this.suffixIcon,
    this.keyboardType,
    this.textInputAction,
    this.onSubmitted,
    this.readOnly = false,
    this.enabled = true,
    this.obscureText = false,
    this.showVisibilityToggle = true,
    this.minLines = 1,
    this.maxLines = 1,
    this.textAlign = TextAlign.right,
    this.autofillHints,
    this.onTap,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;
  final String? label;
  final String? hint;
  final IconData? prefixIcon;
  final Widget? suffixIcon;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;
  final bool readOnly;
  final bool enabled;
  final bool obscureText;
  final bool showVisibilityToggle;
  final int minLines;
  final int maxLines;
  final TextAlign textAlign;
  final Iterable<String>? autofillHints;
  final VoidCallback? onTap;

  @override
  State<AppInput> createState() => _AppInputState();
}

class _AppInputState extends State<AppInput> {
  late final FocusNode _internalFocusNode = widget.focusNode ?? FocusNode();
  late bool _obscured = widget.obscureText;

  FocusNode get _focusNode => widget.focusNode ?? _internalFocusNode;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_handleFocusChanged);
  }

  @override
  void didUpdateWidget(covariant AppInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode?.removeListener(_handleFocusChanged);
      _focusNode.addListener(_handleFocusChanged);
    }
    if (oldWidget.obscureText != widget.obscureText) {
      _obscured = widget.obscureText;
    }
  }

  void _handleFocusChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _focusNode.removeListener(_handleFocusChanged);
    if (widget.focusNode == null) {
      _internalFocusNode.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final focused = _focusNode.hasFocus;
    final showLines = widget.obscureText ? 1 : widget.maxLines;
    final showMinLines = widget.obscureText ? 1 : widget.minLines;

    Widget? trailing = widget.suffixIcon;
    if (widget.obscureText && widget.showVisibilityToggle) {
      trailing = IconButton(
        splashRadius: 18,
        onPressed: widget.enabled
            ? () => setState(() => _obscured = !_obscured)
            : null,
        icon: Icon(
          _obscured ? Icons.visibility_off_outlined : Icons.visibility_outlined,
          color: focused ? AppTheme.primary : AppTheme.textMuted,
          size: 20,
        ),
      );
    }

    return AnimatedContainer(
      duration: kIsWeb ? Duration.zero : AppTheme.sectionTransitionDuration,
      curve: AppTheme.emphasizedCurve,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        color: widget.enabled ? Colors.white : AppTheme.surfaceMuted,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: focused ? AppTheme.primary : AppTheme.border,
          width: focused ? 1.2 : 1,
        ),
        boxShadow: [
          BoxShadow(
            color: focused
                ? AppTheme.primary.withValues(alpha: 0.16)
                : const Color(0x0A000000),
            blurRadius: focused ? 24 : 16,
            offset: Offset(0, focused ? 14 : 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if ((widget.label ?? '').trim().isNotEmpty) ...[
            AppText(
              widget.label!,
              role: AppTextRole.caption,
              color: focused ? AppTheme.primary : AppTheme.textMuted,
            ),
            const SizedBox(height: 8),
          ],
          Row(
            crossAxisAlignment: showLines > 1
                ? CrossAxisAlignment.start
                : CrossAxisAlignment.center,
            children: [
              if (trailing != null) ...[
                trailing,
                const SizedBox(width: 8),
              ],
              Expanded(
                child: TextField(
                  controller: widget.controller,
                  focusNode: _focusNode,
                  enabled: widget.enabled,
                  readOnly: widget.readOnly,
                  obscureText: _obscured,
                  keyboardType: widget.keyboardType,
                  textInputAction: widget.textInputAction,
                  onSubmitted: widget.onSubmitted,
                  onTap: widget.onTap,
                  minLines: showMinLines,
                  maxLines: showLines,
                  textAlign: widget.textAlign,
                  autofillHints: widget.autofillHints,
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: AppTheme.text,
                        fontWeight: FontWeight.w700,
                      ),
                  decoration: InputDecoration.collapsed(
                    hintText: widget.hint,
                    hintStyle: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: AppTheme.textMuted,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ),
              ),
              if (widget.prefixIcon != null) ...[
                const SizedBox(width: 12),
                Icon(
                  widget.prefixIcon,
                  color: focused ? AppTheme.primary : AppTheme.textMuted,
                  size: 20,
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
