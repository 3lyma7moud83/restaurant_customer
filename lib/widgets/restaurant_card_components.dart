import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../core/localization/app_localizations.dart';
import '../core/theme/app_theme.dart';

const Duration _kCardAnimationDuration = AppTheme.sectionTransitionDuration;
const BorderRadius _kRestaurantCardRadius = BorderRadius.all(
  Radius.circular(18),
);

class AppCachedImage extends StatelessWidget {
  const AppCachedImage({
    super.key,
    required this.imageUrl,
    this.fit = BoxFit.cover,
    this.borderRadius,
    this.width,
    this.height,
    this.placeholder = const _ShimmerPlaceholder(),
    this.errorWidget = const ImageFallback(),
  });

  final String? imageUrl;
  final BoxFit fit;
  final BorderRadius? borderRadius;
  final double? width;
  final double? height;
  final Widget placeholder;
  final Widget errorWidget;

  int? _cacheDimension(double? value) {
    if (value == null || !value.isFinite || value <= 0) {
      return null;
    }

    final normalized = value.clamp(40.0, 2400.0).round();
    return normalized <= 0 ? null : normalized;
  }

  @override
  Widget build(BuildContext context) {
    final normalizedUrl = imageUrl?.trim();

    final imageChild = normalizedUrl == null || normalizedUrl.isEmpty
        ? errorWidget
        : kIsWeb
            ? Image.network(
                normalizedUrl,
                width: width,
                height: height,
                fit: fit,
                gaplessPlayback: true,
                loadingBuilder: (context, child, progress) {
                  if (progress == null) {
                    return child;
                  }
                  return placeholder;
                },
                errorBuilder: (_, __, ___) => errorWidget,
              )
            : CachedNetworkImage(
                imageUrl: normalizedUrl,
                width: width,
                height: height,
                fit: fit,
                memCacheWidth: _cacheDimension(width),
                memCacheHeight: _cacheDimension(height),
                fadeInDuration: const Duration(milliseconds: 160),
                fadeOutDuration: const Duration(milliseconds: 90),
                placeholder: (_, __) => placeholder,
                errorWidget: (_, __, ___) => errorWidget,
              );

    if (borderRadius == null) {
      return imageChild;
    }

    return ClipRRect(
      borderRadius: borderRadius!,
      child: imageChild,
    );
  }
}

class RestaurantCardImage extends StatelessWidget {
  const RestaurantCardImage({
    super.key,
    required this.imageUrl,
    this.borderRadius,
  });

  final String? imageUrl;
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AppCachedImage(
        imageUrl: imageUrl,
        borderRadius: borderRadius,
        placeholder: const _ShimmerPlaceholder(),
        errorWidget: const ImageFallback(
          icon: Icons.storefront_rounded,
          iconSize: 34,
          circular: false,
        ),
      ),
    );
  }
}

class ImageFallback extends StatelessWidget {
  const ImageFallback({
    super.key,
    this.icon = Icons.storefront_rounded,
    this.iconSize = 28,
    this.circular = false,
  });

  final IconData icon;
  final double iconSize;
  final bool circular;

  @override
  Widget build(BuildContext context) {
    final decoration = BoxDecoration(
      color: const Color(0xFFF1F1F1),
      shape: circular ? BoxShape.circle : BoxShape.rectangle,
      borderRadius: circular ? null : BorderRadius.circular(12),
    );

    return DecoratedBox(
      decoration: decoration,
      child: Center(
        child: Icon(
          icon,
          color: Colors.black26,
          size: iconSize,
        ),
      ),
    );
  }
}

class RestaurantListCard extends StatelessWidget {
  const RestaurantListCard({
    super.key,
    required this.name,
    required this.imageUrl,
    required this.deliveryMinutes,
    required this.categoryLabel,
    required this.distanceLabel,
    required this.statusLabel,
    required this.statusPositive,
    required this.onTap,
    this.onInfoTap,
  });

  final String name;
  final String? imageUrl;
  final int? deliveryMinutes;
  final String? categoryLabel;
  final String? distanceLabel;
  final String statusLabel;
  final bool statusPositive;
  final VoidCallback onTap;
  final VoidCallback? onInfoTap;

  @override
  Widget build(BuildContext context) {
    final displayName =
        name.trim().isEmpty ? context.tr('common.restaurant') : name.trim();

    return Align(
      alignment: Alignment.topCenter,
      child: _InteractiveRestaurantCard(
        onTap: onTap,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final metrics = _RestaurantCardMetrics.fromConstraints(constraints);
            final safeDeliveryMinutes = deliveryMinutes;
            final minutesText = safeDeliveryMinutes == null
                ? null
                : '${safeDeliveryMinutes.clamp(1, 300)} '
                    '${context.tr('common.minutes')}';
            final normalizedCategory = categoryLabel?.trim().isNotEmpty == true
                ? categoryLabel!.trim()
                : null;
            final normalizedDistance = distanceLabel?.trim().isNotEmpty == true
                ? distanceLabel!.trim()
                : null;
            final normalizedStatus = statusLabel.trim().isEmpty
                ? context.tr('common.open_now')
                : statusLabel.trim();
            final metaWidgets = <Widget>[
              if (minutesText != null)
                _InlineMetaPill(
                  icon: Icons.schedule_rounded,
                  label: minutesText,
                  fontSize: metrics.metaFontSize,
                  iconSize: metrics.metaIconSize,
                  iconColor: AppTheme.textMuted,
                ),
            ];
            final infoBadges = <Widget>[
              if (normalizedCategory != null)
                _InfoBadge(
                  label: normalizedCategory,
                  fontSize: metrics.badgeFontSize,
                  icon: Icons.local_dining_rounded,
                  iconSize: metrics.badgeIconSize,
                  background: const Color(0xFFF8F5EF),
                ),
              if (normalizedDistance != null)
                _InfoBadge(
                  label: normalizedDistance,
                  fontSize: metrics.badgeFontSize,
                  icon: Icons.place_rounded,
                  iconSize: metrics.badgeIconSize,
                  background: const Color(0xFFF4F7FA),
                ),
            ];
            final statusBadge = _InfoBadge(
              label: normalizedStatus,
              fontSize: metrics.badgeFontSize,
              icon: statusPositive
                  ? Icons.check_circle_rounded
                  : Icons.pause_circle_rounded,
              iconSize: metrics.badgeIconSize,
              background: statusPositive
                  ? const Color(0xFFE9F7EF)
                  : const Color(0xFFF5F0F0),
              foreground: statusPositive
                  ? const Color(0xFF177A49)
                  : const Color(0xFF7A3A3A),
            );
            final hasMetaSection =
                metaWidgets.isNotEmpty || infoBadges.isNotEmpty;

            return Padding(
              padding: EdgeInsets.all(metrics.contentPadding),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: metrics.imageWidth,
                    height: metrics.imageHeight,
                    child: RestaurantCardImage(
                      imageUrl: imageUrl,
                      borderRadius: BorderRadius.circular(metrics.imageRadius),
                    ),
                  ),
                  SizedBox(width: metrics.horizontalGap),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Text(
                                displayName,
                                maxLines: metrics.titleMaxLines,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.start,
                                style: TextStyle(
                                  fontSize: metrics.titleFontSize,
                                  height: 1.2,
                                  fontWeight: FontWeight.w800,
                                  color: AppTheme.text,
                                ),
                              ),
                            ),
                            if (onInfoTap != null) ...[
                              SizedBox(width: metrics.titleToInfoGap),
                              _OverflowActionButton(
                                onTap: onInfoTap!,
                                padding: metrics.infoPadding,
                                iconSize: metrics.infoIconSize,
                              ),
                            ],
                          ],
                        ),
                        if (hasMetaSection)
                          SizedBox(height: metrics.blockSpacing),
                        if (metaWidgets.isNotEmpty) ...[
                          Wrap(
                            spacing: metrics.metaSpacing,
                            runSpacing: metrics.metaRunSpacing,
                            children: metaWidgets,
                          ),
                          SizedBox(height: metrics.badgeSectionSpacing),
                        ],
                        if (infoBadges.isNotEmpty) ...[
                          Wrap(
                            spacing: metrics.badgeSpacing,
                            runSpacing: metrics.badgeRunSpacing,
                            children: infoBadges,
                          ),
                          SizedBox(height: metrics.badgeSectionSpacing),
                        ],
                        _StatusAndCtaRow(
                          spacing: metrics.statusToCtaSpacing,
                          badgeSpacing: metrics.badgeSpacing,
                          badgeRunSpacing: metrics.badgeRunSpacing,
                          statusBadge: statusBadge,
                          menuBadge: _MenuCtaBadge(
                            fontSize: metrics.ctaFontSize,
                            iconSize: metrics.ctaIconSize,
                            label: context.tr('common.view_menu'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class RestaurantGridSkeleton extends StatelessWidget {
  const RestaurantGridSkeleton({
    super.key,
    required this.crossAxisCount,
    required this.childAspectRatio,
    this.itemCount = 6,
    this.padding = EdgeInsets.zero,
    this.mainAxisSpacing = 12,
    this.crossAxisSpacing = 12,
    this.physics,
  });

  final int crossAxisCount;
  final double childAspectRatio;
  final int itemCount;
  final EdgeInsets padding;
  final double mainAxisSpacing;
  final double crossAxisSpacing;
  final ScrollPhysics? physics;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: padding,
      physics: physics ?? const NeverScrollableScrollPhysics(),
      cacheExtent: 360,
      itemCount: itemCount,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        mainAxisSpacing: mainAxisSpacing,
        crossAxisSpacing: crossAxisSpacing,
        childAspectRatio: childAspectRatio,
      ),
      itemBuilder: (_, __) => const _RestaurantSkeletonCard(),
    );
  }
}

class _RestaurantSkeletonCard extends StatelessWidget {
  const _RestaurantSkeletonCard();

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: _kRestaurantCardRadius,
          boxShadow: const [
            BoxShadow(
              color: Color(0x14000000),
              blurRadius: 16,
              offset: Offset(0, 8),
            ),
          ],
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final metrics = _RestaurantCardMetrics.fromConstraints(constraints);
            final titleWidth =
                (constraints.maxWidth * 0.48).clamp(120.0, 220.0);
            final subtitleWidth =
                (constraints.maxWidth * 0.36).clamp(84.0, 170.0);

            return Padding(
              padding: EdgeInsets.all(metrics.contentPadding),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _ImageSkeleton(
                    width: metrics.imageWidth,
                    height: metrics.imageHeight,
                    borderRadius: metrics.imageRadius,
                  ),
                  SizedBox(width: metrics.horizontalGap),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _SkeletonLine(
                          width: titleWidth.toDouble(),
                          height: metrics.titleLineHeight,
                        ),
                        SizedBox(height: metrics.blockSpacing),
                        _SkeletonLine(
                          width: subtitleWidth.toDouble(),
                          height: metrics.subtitleLineHeight,
                        ),
                        SizedBox(height: metrics.blockSpacing),
                        Wrap(
                          spacing: metrics.metaSpacing,
                          runSpacing: metrics.metaRunSpacing,
                          children: [
                            _SkeletonPill(
                              width: metrics.metaPillWidth,
                              height: metrics.metaPillHeight,
                            ),
                          ],
                        ),
                        SizedBox(height: metrics.badgeSectionSpacing),
                        Wrap(
                          spacing: metrics.badgeSpacing,
                          runSpacing: metrics.badgeRunSpacing,
                          children: [
                            _SkeletonPill(
                              width: metrics.badgePillWidth,
                              height: metrics.badgePillHeight,
                            ),
                            _SkeletonPill(
                              width: metrics.badgePillWideWidth,
                              height: metrics.badgePillHeight,
                            ),
                            _SkeletonPill(
                              width: metrics.badgePillWidth,
                              height: metrics.badgePillHeight,
                            ),
                          ],
                        ),
                        SizedBox(height: metrics.badgeSectionSpacing),
                        _SkeletonLine(
                          width:
                              (constraints.maxWidth * 0.28).clamp(86.0, 140.0),
                          height: metrics.subtitleLineHeight,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _ImageSkeleton extends StatelessWidget {
  const _ImageSkeleton({
    required this.width,
    required this.height,
    required this.borderRadius,
  });

  final double width;
  final double height;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: const _ShimmerPlaceholder(),
      ),
    );
  }
}

class _SkeletonLine extends StatelessWidget {
  const _SkeletonLine({
    required this.width,
    required this.height,
  });

  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: const Color(0xFFE9E9E9),
        borderRadius: BorderRadius.circular(999),
      ),
    );
  }
}

class _SkeletonPill extends StatelessWidget {
  const _SkeletonPill({
    required this.width,
    required this.height,
  });

  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: const Color(0xFFEDEDED),
        borderRadius: BorderRadius.circular(999),
      ),
    );
  }
}

class _RestaurantCardMetrics {
  const _RestaurantCardMetrics({
    required this.contentPadding,
    required this.imageWidth,
    required this.imageHeight,
    required this.imageRadius,
    required this.horizontalGap,
    required this.titleMaxLines,
    required this.titleFontSize,
    required this.titleToInfoGap,
    required this.infoPadding,
    required this.infoIconSize,
    required this.blockSpacing,
    required this.metaSpacing,
    required this.metaRunSpacing,
    required this.metaFontSize,
    required this.metaIconSize,
    required this.badgeSectionSpacing,
    required this.badgeSpacing,
    required this.badgeRunSpacing,
    required this.badgeFontSize,
    required this.badgeIconSize,
    required this.statusToCtaSpacing,
    required this.ctaFontSize,
    required this.ctaIconSize,
    required this.titleLineHeight,
    required this.subtitleLineHeight,
    required this.metaPillHeight,
    required this.metaPillWidth,
    required this.metaPillWideWidth,
    required this.badgePillHeight,
    required this.badgePillWidth,
    required this.badgePillWideWidth,
  });

  factory _RestaurantCardMetrics.fromConstraints(BoxConstraints constraints) {
    final width = constraints.maxWidth.clamp(240.0, 620.0).toDouble();
    final compact = width < 360;
    final roomy = width >= 440;
    final contentPadding = compact
        ? 7.0
        : roomy
            ? 9.0
            : 8.0;
    final imageWidth =
        (width * (compact ? 0.30 : 0.28)).clamp(84.0, 124.0).toDouble();
    final imageHeight = compact
        ? 82.0
        : roomy
            ? 90.0
            : 86.0;

    return _RestaurantCardMetrics(
      contentPadding: contentPadding,
      imageWidth: imageWidth,
      imageHeight: imageHeight,
      imageRadius: compact ? 12.0 : 14.0,
      horizontalGap: compact ? 7.0 : 9.0,
      titleMaxLines: compact ? 1 : 2,
      titleFontSize: compact
          ? 14.2
          : roomy
              ? 15.8
              : 14.9,
      titleToInfoGap: compact ? 5.0 : 6.0,
      infoPadding: compact ? 4.2 : 4.8,
      infoIconSize: compact ? 15.0 : 16.2,
      blockSpacing: compact ? 2.6 : 3.2,
      metaSpacing: compact ? 5.0 : 6.0,
      metaRunSpacing: compact ? 3.4 : 4.0,
      metaFontSize: compact ? 10.2 : 10.8,
      metaIconSize: compact ? 12.4 : 13.2,
      badgeSectionSpacing: compact ? 2.8 : 3.4,
      badgeSpacing: compact ? 4.6 : 5.4,
      badgeRunSpacing: compact ? 3.4 : 4.0,
      badgeFontSize: compact ? 9.9 : 10.6,
      badgeIconSize: compact ? 12.2 : 13.2,
      statusToCtaSpacing: compact ? 4.0 : 5.0,
      ctaFontSize: compact ? 9.9 : 10.6,
      ctaIconSize: compact ? 13.4 : 14.4,
      titleLineHeight: compact ? 12.0 : 13.0,
      subtitleLineHeight: compact ? 10.0 : 11.0,
      metaPillHeight: compact ? 20.0 : 22.0,
      metaPillWidth: compact ? 56.0 : 66.0,
      metaPillWideWidth: compact ? 78.0 : 92.0,
      badgePillHeight: compact ? 19.0 : 21.0,
      badgePillWidth: compact ? 64.0 : 74.0,
      badgePillWideWidth: compact ? 78.0 : 92.0,
    );
  }

  final double contentPadding;
  final double imageWidth;
  final double imageHeight;
  final double imageRadius;
  final double horizontalGap;
  final int titleMaxLines;
  final double titleFontSize;
  final double titleToInfoGap;
  final double infoPadding;
  final double infoIconSize;
  final double blockSpacing;
  final double metaSpacing;
  final double metaRunSpacing;
  final double metaFontSize;
  final double metaIconSize;
  final double badgeSectionSpacing;
  final double badgeSpacing;
  final double badgeRunSpacing;
  final double badgeFontSize;
  final double badgeIconSize;
  final double statusToCtaSpacing;
  final double ctaFontSize;
  final double ctaIconSize;
  final double titleLineHeight;
  final double subtitleLineHeight;
  final double metaPillHeight;
  final double metaPillWidth;
  final double metaPillWideWidth;
  final double badgePillHeight;
  final double badgePillWidth;
  final double badgePillWideWidth;
}

class _OverflowActionButton extends StatelessWidget {
  const _OverflowActionButton({
    required this.onTap,
    required this.padding,
    required this.iconSize,
  });

  final VoidCallback onTap;
  final double padding;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFFFFFAF3),
      borderRadius: BorderRadius.circular(999),
      elevation: 0,
      shadowColor: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          padding: EdgeInsets.all(padding + 1),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: AppTheme.border.withValues(alpha: 0.95),
            ),
            boxShadow: const [
              BoxShadow(
                color: Color(0x11000000),
                blurRadius: 8,
                offset: Offset(0, 4),
              ),
            ],
          ),
          child: Icon(
            Icons.error_outline_rounded,
            size: iconSize,
            color: AppTheme.primaryDeep,
          ),
        ),
      ),
    );
  }
}

class _StatusAndCtaRow extends StatelessWidget {
  const _StatusAndCtaRow({
    required this.spacing,
    required this.badgeSpacing,
    required this.badgeRunSpacing,
    required this.statusBadge,
    required this.menuBadge,
  });

  final double spacing;
  final double badgeSpacing;
  final double badgeRunSpacing;
  final Widget statusBadge;
  final Widget menuBadge;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 260;
        if (narrow) {
          return Wrap(
            spacing: badgeSpacing,
            runSpacing: badgeRunSpacing,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              statusBadge,
              menuBadge,
            ],
          );
        }

        return Row(
          children: [
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: statusBadge,
              ),
            ),
            SizedBox(width: spacing),
            Flexible(
              child: Align(
                alignment: Alignment.centerRight,
                child: menuBadge,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _MenuCtaBadge extends StatelessWidget {
  const _MenuCtaBadge({
    required this.fontSize,
    required this.iconSize,
    required this.label,
  });

  final double fontSize;
  final double iconSize;
  final String label;

  @override
  Widget build(BuildContext context) {
    final maxChipWidth =
        (MediaQuery.sizeOf(context).width * 0.40).clamp(116.0, 220.0);
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxChipWidth.toDouble()),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppTheme.primary.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: AppTheme.primary.withValues(alpha: 0.24)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.menu_book_rounded,
                  size: iconSize, color: AppTheme.primaryDeep),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  '$label \u2192',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppTheme.primaryDeep,
                    fontWeight: FontWeight.w800,
                    fontSize: fontSize,
                    height: 1.15,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InlineMetaPill extends StatelessWidget {
  const _InlineMetaPill({
    required this.icon,
    required this.label,
    required this.fontSize,
    required this.iconSize,
    required this.iconColor,
  });

  final IconData icon;
  final String label;
  final double fontSize;
  final double iconSize;
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFFF6F7F9),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: iconSize, color: iconColor),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                color: AppTheme.text,
                fontWeight: FontWeight.w700,
                fontSize: fontSize,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoBadge extends StatelessWidget {
  const _InfoBadge({
    required this.label,
    required this.fontSize,
    required this.icon,
    required this.iconSize,
    required this.background,
    this.foreground,
  });

  final String label;
  final double fontSize;
  final IconData icon;
  final double iconSize;
  final Color background;
  final Color? foreground;

  @override
  Widget build(BuildContext context) {
    final textColor = foreground ?? AppTheme.textMuted;
    final maxChipWidth =
        (MediaQuery.sizeOf(context).width * 0.40).clamp(110.0, 212.0);
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxChipWidth.toDouble()),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: iconSize, color: textColor),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: textColor,
                    fontWeight: FontWeight.w700,
                    fontSize: fontSize,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InteractiveRestaurantCard extends StatefulWidget {
  const _InteractiveRestaurantCard({
    required this.child,
    required this.onTap,
  });

  final Widget child;
  final VoidCallback onTap;

  @override
  State<_InteractiveRestaurantCard> createState() =>
      _InteractiveRestaurantCardState();
}

class _InteractiveRestaurantCardState
    extends State<_InteractiveRestaurantCard> {
  bool _pressed = false;
  bool _hovered = false;

  void _updateInteractionState({
    bool? pressed,
    bool? hovered,
  }) {
    final nextPressed = pressed ?? _pressed;
    final nextHovered = hovered ?? _hovered;
    if (!mounted || (_pressed == nextPressed && _hovered == nextHovered)) {
      return;
    }

    void applyUpdate() {
      if (!mounted || (_pressed == nextPressed && _hovered == nextHovered)) {
        return;
      }
      setState(() {
        _pressed = nextPressed;
        _hovered = nextHovered;
      });
    }

    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => applyUpdate());
      return;
    }

    applyUpdate();
  }

  void _setPressed(bool value) {
    _updateInteractionState(pressed: value);
  }

  void _setHovered(bool value) {
    _updateInteractionState(hovered: value);
  }

  @override
  Widget build(BuildContext context) {
    final enableAnimations =
        !kIsWeb || defaultTargetPlatform == TargetPlatform.android;
    final duration = enableAnimations ? _kCardAnimationDuration : Duration.zero;
    const interactionCurve = Curves.easeOutBack;

    final shadowColor = _pressed
        ? const Color(0x17000000)
        : _hovered
            ? const Color(0x1D000000)
            : const Color(0x12000000);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => _setHovered(true),
      onExit: (_) {
        _setHovered(false);
        _setPressed(false);
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onTapDown: (_) => _setPressed(true),
        onTapUp: (_) => _setPressed(false),
        onTapCancel: () => _setPressed(false),
        child: AnimatedScale(
          scale: enableAnimations
              ? (_pressed ? 0.978 : (_hovered ? 1.004 : 1))
              : 1,
          duration: enableAnimations
              ? const Duration(milliseconds: 180)
              : Duration.zero,
          curve: interactionCurve,
          child: AnimatedSlide(
            duration: duration,
            curve: AppTheme.emphasizedCurve,
            offset: enableAnimations
                ? (_pressed
                    ? const Offset(0, 0.008)
                    : (_hovered ? const Offset(0, -0.004) : Offset.zero))
                : Offset.zero,
            child: AnimatedContainer(
              duration: duration,
              curve: interactionCurve,
              decoration: BoxDecoration(
                borderRadius: _kRestaurantCardRadius,
                boxShadow: [
                  BoxShadow(
                    color: shadowColor,
                    blurRadius: enableAnimations
                        ? (_hovered ? 22 : (_pressed ? 11 : 16))
                        : 14,
                    offset: enableAnimations
                        ? Offset(0, _hovered ? 13 : (_pressed ? 5 : 9))
                        : const Offset(0, 8),
                  ),
                ],
              ),
              child: Material(
                color: Colors.white,
                borderRadius: _kRestaurantCardRadius,
                clipBehavior: Clip.antiAlias,
                child: widget.child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ShimmerPlaceholder extends StatelessWidget {
  const _ShimmerPlaceholder();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFFE8E8E8),
            Color(0xFFF5F5F5),
            Color(0xFFE8E8E8),
          ],
        ),
      ),
    );
  }
}
