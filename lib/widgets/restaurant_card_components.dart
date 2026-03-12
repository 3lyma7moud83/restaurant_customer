import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';

class PressableScale extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;
  final double pressedScale;
  final Duration duration;
  final BorderRadius borderRadius;

  const PressableScale({
    super.key,
    required this.child,
    required this.onTap,
    this.pressedScale = 0.97,
    this.duration = const Duration(milliseconds: 120),
    this.borderRadius = const BorderRadius.all(Radius.circular(24)),
  });

  @override
  State<PressableScale> createState() => _PressableScaleState();
}

class _PressableScaleState extends State<PressableScale> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value) {
      return;
    }
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedScale(
      scale: _pressed ? widget.pressedScale : 1,
      duration: widget.duration,
      curve: Curves.easeOutCubic,
      child: Material(
        color: Colors.transparent,
        borderRadius: widget.borderRadius,
        child: InkWell(
          borderRadius: widget.borderRadius,
          splashColor: const Color(0x1A000000),
          highlightColor: Colors.transparent,
          onTapDown: (_) => _setPressed(true),
          onTapUp: (_) => _setPressed(false),
          onTapCancel: () => _setPressed(false),
          onTap: widget.onTap,
          child: widget.child,
        ),
      ),
    );
  }
}

class RestaurantCardImage extends StatelessWidget {
  final String? imageUrl;
  final double? width;
  final double height;
  final BorderRadius borderRadius;

  const RestaurantCardImage({
    super.key,
    required this.imageUrl,
    this.width,
    this.height = 148,
    this.borderRadius = const BorderRadius.all(Radius.circular(18)),
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width ?? double.infinity,
      height: height,
      child: _FadeShimmerImage(
        imageUrl: imageUrl,
        borderRadius: borderRadius,
      ),
    );
  }
}

class _FadeShimmerImage extends StatefulWidget {
  final String? imageUrl;
  final BorderRadius borderRadius;

  const _FadeShimmerImage({
    required this.imageUrl,
    required this.borderRadius,
  });

  @override
  State<_FadeShimmerImage> createState() => _FadeShimmerImageState();
}

class _FadeShimmerImageState extends State<_FadeShimmerImage> {
  bool _loaded = false;

  void _markLoaded() {
    if (_loaded) {
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        setState(() => _loaded = true);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final imageUrl = widget.imageUrl?.trim();
    if (imageUrl == null || imageUrl.isEmpty) {
      return ImageFallback(borderRadius: widget.borderRadius);
    }

    return ClipRRect(
      borderRadius: widget.borderRadius,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (!_loaded) const _ShimmerPlaceholder(),
          AnimatedOpacity(
            opacity: _loaded ? 1 : 0,
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOut,
            child: Image.network(
              imageUrl,
              fit: BoxFit.cover,
              loadingBuilder: (context, child, loadingProgress) {
                if (loadingProgress == null) {
                  _markLoaded();
                }
                return child;
              },
              errorBuilder: (context, error, stackTrace) {
                _markLoaded();
                return ImageFallback(borderRadius: widget.borderRadius);
              },
            ),
          ),
        ],
      ),
    );
  }
}

class ImageFallback extends StatelessWidget {
  final BorderRadius borderRadius;

  const ImageFallback({
    super.key,
    required this.borderRadius,
  });

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFFF1F1F1),
        borderRadius: borderRadius,
      ),
      child: const Center(
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
  final String name;
  final String? imageUrl;
  final VoidCallback onTap;
  final VoidCallback? onInfoTap;

  const RestaurantListCard({
    super.key,
    required this.name,
    required this.imageUrl,
    required this.onTap,
    this.onInfoTap,
  });

  @override
  Widget build(BuildContext context) {
    final cardBorderRadius = BorderRadius.circular(22);

    return PressableScale(
      onTap: onTap,
      borderRadius: cardBorderRadius,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: cardBorderRadius,
          boxShadow: const [
            BoxShadow(
              color: Color(0x16000000),
              blurRadius: 16,
              offset: Offset(0, 8),
            ),
          ],
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final imageHeight =
                (constraints.maxHeight * 0.62).clamp(104.0, 148.0);

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Stack(
                  children: [
                    RestaurantCardImage(
                      imageUrl: imageUrl,
                      height: imageHeight,
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(22),
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
                Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(12, 10, 12, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        name.trim().isEmpty ? 'مطعم' : name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.right,
                        style: const TextStyle(
                          fontSize: 16,
                          height: 1.2,
                          fontWeight: FontWeight.w800,
                          color: AppTheme.text,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: const [
                          Icon(
                            Icons.arrow_back_rounded,
                            size: 16,
                            color: Color(0xFF98A2B3),
                          ),
                          Spacer(),
                          Text(
                            'عرض القائمة',
                            style: TextStyle(
                              color: AppTheme.primary,
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _ShimmerPlaceholder extends StatefulWidget {
  const _ShimmerPlaceholder();

  @override
  State<_ShimmerPlaceholder> createState() => _ShimmerPlaceholderState();
}

class _ShimmerPlaceholderState extends State<_ShimmerPlaceholder>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final slide = _controller.value;
        return DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment(-1.6 + (2.2 * slide), -0.2),
              end: Alignment(0.2 + (2.2 * slide), 0.2),
              colors: const [
                Color(0xFFE8E8E8),
                Color(0xFFF5F5F5),
                Color(0xFFE8E8E8),
              ],
              stops: const [0.15, 0.5, 0.85],
            ),
          ),
        );
      },
    );
  }
}
