import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';

const Duration _kCardAnimationDuration = AppTheme.sectionTransitionDuration;
const BorderRadius _kRestaurantCardRadius = BorderRadius.all(
  Radius.circular(22),
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

  @override
  Widget build(BuildContext context) {
    final normalizedUrl = imageUrl?.trim();
    final imageChild = normalizedUrl == null || normalizedUrl.isEmpty
        ? errorWidget
        : Image.network(
            normalizedUrl,
            width: width,
            height: height,
            fit: fit,
            filterQuality: FilterQuality.medium,
            gaplessPlayback: true,
            frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
              if (frame != null || wasSynchronouslyLoaded) {
                return child;
              }
              return placeholder;
            },
            loadingBuilder: (context, child, loadingProgress) {
              if (loadingProgress == null) {
                return child;
              }
              return placeholder;
            },
            errorBuilder: (_, __, ___) => errorWidget,
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
  });

  final String? imageUrl;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1,
      child: RepaintBoundary(
        child: AppCachedImage(
          imageUrl: imageUrl,
          placeholder: const _ShimmerPlaceholder(),
          errorWidget: const ImageFallback(),
        ),
      ),
    );
  }
}

class ImageFallback extends StatelessWidget {
  const ImageFallback({super.key});

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(color: Color(0xFFF1F1F1)),
      child: Center(
        child: Icon(
          Icons.storefront_rounded,
          color: Colors.black26,
          size: 28,
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
    return _InteractiveRestaurantCard(
      onTap: onTap,
      child: Stack(
        fit: StackFit.expand,
        children: [
          RepaintBoundary(
            child: RestaurantCardImage(imageUrl: imageUrl),
          ),
          const Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Color(0xB3000000),
                    ],
                    stops: [0.52, 1.0],
                  ),
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: onTap,
                splashFactory: NoSplash.splashFactory,
                overlayColor: WidgetStateProperty.resolveWith((states) {
                  if (states.contains(WidgetState.pressed)) {
                    return Colors.white.withValues(alpha: 0.08);
                  }
                  if (states.contains(WidgetState.hovered)) {
                    return Colors.white.withValues(alpha: 0.04);
                  }
                  return null;
                }),
              ),
            ),
          ),
          PositionedDirectional(
            start: 12,
            end: 12,
            bottom: 12,
            child: IgnorePointer(
              child: _RestaurantCardOverlay(name: name),
            ),
          ),
          if (onInfoTap != null)
            PositionedDirectional(
              top: 10,
              start: 10,
              child: Material(
                color: Colors.white.withValues(alpha: 0.92),
                borderRadius: BorderRadius.circular(14),
                child: InkWell(
                  onTap: onInfoTap,
                  borderRadius: BorderRadius.circular(14),
                  splashFactory: NoSplash.splashFactory,
                  overlayColor: WidgetStateProperty.resolveWith((states) {
                    if (states.contains(WidgetState.pressed)) {
                      return AppTheme.primary.withValues(alpha: 0.08);
                    }
                    if (states.contains(WidgetState.hovered)) {
                      return AppTheme.primary.withValues(alpha: 0.04);
                    }
                    return null;
                  }),
                  child: const Padding(
                    padding: EdgeInsets.all(7),
                    child: Icon(
                      Icons.info_outline_rounded,
                      size: 17,
                      color: AppTheme.text,
                    ),
                  ),
                ),
              ),
            ),
        ],
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
    return GridView.builder(
      padding: padding,
      physics: physics ?? const NeverScrollableScrollPhysics(),
      cacheExtent: 360,
      itemCount: itemCount,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        mainAxisSpacing: 14,
        crossAxisSpacing: 14,
        childAspectRatio: 1,
      ),
      itemBuilder: (_, __) => const _RestaurantSkeletonCard(),
    );
  }
}

class _RestaurantCardOverlay extends StatelessWidget {
  const _RestaurantCardOverlay({
    required this.name,
  });

  final String name;

  @override
  Widget build(BuildContext context) {
    final displayName = name.trim().isEmpty ? 'مطعم' : name;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          displayName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.right,
          style: const TextStyle(
            fontSize: 15,
            height: 1.2,
            fontWeight: FontWeight.w900,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 6),
        const Row(
          children: [
            Icon(
              Icons.arrow_back_rounded,
              size: 16,
              color: Color(0xDFFFFFFF),
            ),
            Spacer(),
            Flexible(
              child: Text(
                'عرض القائمة',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Color(0xF2FFFFFF),
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _RestaurantSkeletonCard extends StatelessWidget {
  const _RestaurantSkeletonCard();

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(borderRadius: _kRestaurantCardRadius),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: const [
          _ShimmerPlaceholder(),
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Color(0x40000000),
                  ],
                  stops: [0.55, 1.0],
                ),
              ),
            ),
          ),
          PositionedDirectional(
            start: 12,
            end: 12,
            bottom: 12,
            child: _SkeletonTextBlock(),
          ),
        ],
      ),
    );
  }
}

class _SkeletonTextBlock extends StatelessWidget {
  const _SkeletonTextBlock();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: const [
        _SkeletonLine(width: 108),
        SizedBox(height: 8),
        _SkeletonLine(width: 82),
      ],
    );
  }
}

class _SkeletonLine extends StatelessWidget {
  const _SkeletonLine({
    required this.width,
  });

  final double width;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        width: width,
        height: 10,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(999),
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
  bool get _enableAnimations => !kIsWeb;

  void _setPressed(bool value) {
    if (_pressed == value || !mounted) {
      return;
    }
    setState(() => _pressed = value);
  }

  void _setHovered(bool value) {
    if (_hovered == value || !mounted) {
      return;
    }
    setState(() => _hovered = value);
  }

  @override
  Widget build(BuildContext context) {
    final duration =
        _enableAnimations ? _kCardAnimationDuration : Duration.zero;
    final shadowColor = _pressed
        ? const Color(0x14000000)
        : _hovered
            ? const Color(0x22000000)
            : const Color(0x16000000);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => _setHovered(true),
      onExit: (_) {
        _setHovered(false);
        _setPressed(false);
      },
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => _setPressed(true),
        onPointerUp: (_) => _setPressed(false),
        onPointerCancel: (_) => _setPressed(false),
        child: AnimatedScale(
          scale: _enableAnimations && _pressed ? 0.97 : 1,
          duration:
              _enableAnimations ? AppTheme.microInteractionDuration : duration,
          curve: AppTheme.emphasizedCurve,
          child: AnimatedContainer(
            duration: duration,
            curve: AppTheme.emphasizedCurve,
            decoration: BoxDecoration(
              borderRadius: _kRestaurantCardRadius,
              boxShadow: [
                BoxShadow(
                  color: shadowColor,
                  blurRadius: _enableAnimations
                      ? (_pressed ? 18 : (_hovered ? 28 : 22))
                      : 20,
                  offset: _enableAnimations
                      ? Offset(0, _pressed ? 8 : (_hovered ? 18 : 14))
                      : const Offset(0, 12),
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
