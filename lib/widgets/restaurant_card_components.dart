import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../core/localization/app_localizations.dart';
import '../core/theme/app_theme.dart';
import '../services/restaurant_feed_utils.dart';

const Duration _kCardAnimationDuration = AppTheme.sectionTransitionDuration;
const BorderRadius _kRestaurantCardRadius = BorderRadius.all(
  Radius.circular(16),
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
    required this.onTap,
    this.onInfoTap,
  });

  final String name;
  final String? imageUrl;
  final VoidCallback onTap;
  final VoidCallback? onInfoTap;

  @override
  Widget build(BuildContext context) {
    final displayName =
        name.trim().isEmpty ? context.tr('common.restaurant') : name.trim();

    return _InteractiveRestaurantCard(
      onTap: onTap,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compactLayout =
              constraints.maxWidth < 164 || constraints.maxHeight < 212;
          final imageAspectRatio = compactLayout ? 1.56 : 1.4;
          final sectionSpacing = compactLayout ? 7.0 : 9.0;
          final titleMaxLines = compactLayout ? 1 : 2;
          final actionHeight = compactLayout ? 33.0 : 35.0;
          final contentPadding = compactLayout ? 8.0 : 9.0;

          return Stack(
            children: [
              Padding(
                padding: EdgeInsets.all(contentPadding),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    AspectRatio(
                      aspectRatio: imageAspectRatio,
                      child: RestaurantCardImage(
                        imageUrl: imageUrl,
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    SizedBox(height: sectionSpacing),
                    Text(
                      displayName,
                      maxLines: titleMaxLines,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.start,
                      style: TextStyle(
                        fontSize: compactLayout ? 12.5 : 13.5,
                        height: 1.25,
                        fontWeight: FontWeight.w800,
                        color: AppTheme.text,
                      ),
                    ),
                    SizedBox(height: compactLayout ? 7 : 8),
                    SizedBox(
                      width: double.infinity,
                      height: actionHeight,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: AppTheme.primary,
                          borderRadius: BorderRadius.circular(12),
                          boxShadow: [
                            BoxShadow(
                              color: AppTheme.primary.withValues(alpha: 0.18),
                              blurRadius: 12,
                              offset: const Offset(0, 6),
                            ),
                          ],
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(
                              Icons.menu_book_rounded,
                              size: 15,
                              color: Colors.white,
                            ),
                            const SizedBox(width: 5),
                            Flexible(
                              child: Text(
                                context.tr('common.view_menu'),
                                textAlign: TextAlign.center,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (onInfoTap != null)
                PositionedDirectional(
                  top: 6,
                  end: 6,
                  child: Material(
                    color: const Color(0xFFF8F9FB),
                    borderRadius: BorderRadius.circular(999),
                    child: InkWell(
                      onTap: onInfoTap,
                      borderRadius: BorderRadius.circular(999),
                      child: const Padding(
                        padding: EdgeInsets.all(5.5),
                        child: Icon(
                          Icons.info_outline_rounded,
                          size: 15,
                          color: AppTheme.textMuted,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class RestaurantGridSkeleton extends StatelessWidget {
  const RestaurantGridSkeleton({
    super.key,
    required this.crossAxisCount,
    this.itemCount = 6,
    this.padding = EdgeInsets.zero,
    this.physics,
  });

  final int crossAxisCount;
  final int itemCount;
  final EdgeInsets padding;
  final ScrollPhysics? physics;

  @override
  Widget build(BuildContext context) {
    final compactGrid = crossAxisCount <= 2;
    final mainAxisSpacing = compactGrid ? 10.0 : 12.0;
    final crossAxisSpacing = compactGrid ? 10.0 : 12.0;
    final childAspectRatio = RestaurantFeedUtils.cardAspectRatioFor(
      crossAxisCount,
    );

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
    return DecoratedBox(
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
          final compactLayout =
              constraints.maxWidth < 164 || constraints.maxHeight < 212;
          final imageAspectRatio = compactLayout ? 1.56 : 1.4;
          final contentPadding = compactLayout ? 8.0 : 9.0;

          return Padding(
            padding: EdgeInsets.all(contentPadding),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _ImageSkeleton(aspectRatio: imageAspectRatio),
                SizedBox(height: compactLayout ? 7 : 9),
                const _SkeletonLine(width: 112, height: 11),
                SizedBox(height: compactLayout ? 7 : 8),
                SizedBox(
                  height: compactLayout ? 33 : 35,
                  child: const _SkeletonButton(),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _ImageSkeleton extends StatelessWidget {
  const _ImageSkeleton({
    required this.aspectRatio,
  });

  final double aspectRatio;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: aspectRatio,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: const _ShimmerPlaceholder(),
      ),
    );
  }
}

class _SkeletonButton extends StatelessWidget {
  const _SkeletonButton();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xFFECECEC),
        borderRadius: BorderRadius.circular(12),
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
    final trackInteractionState = !kIsWeb;
    final enableAnimations = trackInteractionState;
    final duration = enableAnimations ? _kCardAnimationDuration : Duration.zero;

    final shadowColor = _pressed
        ? const Color(0x14000000)
        : _hovered
            ? const Color(0x1A000000)
            : const Color(0x12000000);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: trackInteractionState ? (_) => _setHovered(true) : null,
      onExit: trackInteractionState
          ? (_) {
              _setHovered(false);
              _setPressed(false);
            }
          : null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onTapDown: trackInteractionState ? (_) => _setPressed(true) : null,
        onTapUp: trackInteractionState ? (_) => _setPressed(false) : null,
        onTapCancel: trackInteractionState ? () => _setPressed(false) : null,
        child: AnimatedScale(
          scale: enableAnimations && _pressed ? 0.98 : 1,
          duration: enableAnimations
              ? AppTheme.microInteractionDuration
              : Duration.zero,
          curve: AppTheme.emphasizedCurve,
          child: AnimatedContainer(
            duration: duration,
            curve: AppTheme.emphasizedCurve,
            decoration: BoxDecoration(
              borderRadius: _kRestaurantCardRadius,
              boxShadow: [
                BoxShadow(
                  color: shadowColor,
                  blurRadius: enableAnimations
                      ? (_hovered ? 20 : (_pressed ? 10 : 16))
                      : 14,
                  offset: enableAnimations
                      ? Offset(0, _hovered ? 12 : (_pressed ? 5 : 9))
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
