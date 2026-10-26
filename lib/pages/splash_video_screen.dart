import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../core/theme/app_theme.dart';
import 'splash_screen_builders.dart';

/// Covers the real app during startup without replacing its Navigator route.
class SplashVideoScreen<T> extends StatefulWidget {
  const SplashVideoScreen({
    super.key,
    required this.initialization,
    required this.destinationBuilder,
    required this.errorBuilder,
    this.controllerFactory,
  });

  static const assetPath = 'assets/videos/splash.mp4';
  static const posterPath = 'assets/videos/splash_poster.jpg';
  static const visualDuration = Duration(milliseconds: 2500);
  static const fadeDuration = Duration(milliseconds: 180);
  static const background = Color(0xFF0E0F10);

  final Future<T> initialization;
  final SplashDestinationBuilder<T> destinationBuilder;
  final SplashErrorBuilder errorBuilder;

  @visibleForTesting
  final VideoPlayerController Function()? controllerFactory;

  @override
  State<SplashVideoScreen<T>> createState() => _SplashVideoScreenState<T>();
}

class _SplashVideoScreenState<T> extends State<SplashVideoScreen<T>>
    with WidgetsBindingObserver {
  VideoPlayerController? _controller;
  final Stopwatch _visualClock = Stopwatch();
  Timer? _deadlineTimer;
  Timer? _fadeTimer;
  Widget? _destination;
  bool _destinationPainted = false;
  bool _videoReady = false;
  bool _videoRetired = false;
  bool _expired = kIsWeb;
  bool _visible = true;
  bool _fading = false;
  bool _systemUiRestored = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_initializeApp());
    // Web owns its HTML splash before Flutter loads. Never replay it in Flutter.
    if (!kIsWeb) {
      unawaited(_enterImmersiveMode());
      unawaited(_initializeVideo());
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _visualClock.start();
        _fadeTimer = Timer(
          SplashVideoScreen.visualDuration - SplashVideoScreen.fadeDuration,
          () {
            if (mounted && _destinationPainted) {
              setState(() => _fading = true);
            }
          },
        );
        _deadlineTimer = Timer(SplashVideoScreen.visualDuration, _expire);
      });
    }
  }

  Future<void> _initializeApp() async {
    Widget destination;
    try {
      final result = await widget.initialization;
      if (!mounted) return;
      destination = widget.destinationBuilder(context, result);
    } catch (error, stack) {
      if (!mounted) return;
      destination = widget.errorBuilder(context, error, stack);
    }
    setState(() => _destination = destination);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _destinationPainted = true;
      _dismissIfReady();
    });
  }

  bool get _canPlay => mounted && !_expired && !_videoRetired;

  Future<void> _initializeVideo() async {
    final controller = widget.controllerFactory?.call() ??
        VideoPlayerController.asset(
          SplashVideoScreen.assetPath,
          videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
        );
    _controller = controller;
    controller.addListener(_onVideoUpdate);
    try {
      await controller.initialize();
      if (!_canPlay) return;
      await controller.setLooping(false);
      if (!_canPlay) return;
      await controller.setVolume(0);
      if (!_canPlay) return;
      // Fit the complete timeline into the remaining budget after local decode.
      final remaining = SplashVideoScreen.visualDuration - _visualClock.elapsed;
      if (remaining <= Duration.zero) return;
      final speed =
          controller.value.duration.inMicroseconds / remaining.inMicroseconds;
      await controller.setPlaybackSpeed(speed.clamp(1.0, 4.0));
      if (!_canPlay) return;
      await controller.play();
      if (!_canPlay) return;
      setState(() => _videoReady = true);
    } catch (_) {
      // Decode/play errors retain the poster until the same bounded deadline.
      _retireVideo();
      if (mounted) setState(() => _videoReady = false);
    }
  }

  void _onVideoUpdate() {
    if (!_canPlay) return;
    if (_controller!.value.hasError) {
      _retireVideo();
      setState(() => _videoReady = false);
    }
  }

  void _expire() {
    if (!mounted) return;
    setState(() {
      _expired = true;
      _videoReady = false;
    });
    _retireVideo();
    _dismissIfReady();
  }

  void _dismissIfReady() {
    if (!_visible || !_expired || !_destinationPainted) return;
    setState(() => _visible = false);
    unawaited(_restoreSystemUi());
  }

  void _retireVideo() {
    if (_videoRetired) return;
    _videoRetired = true;
    final controller = _controller;
    if (controller != null) {
      controller.removeListener(_onVideoUpdate);
      unawaited(controller.dispose());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_canPlay || !_videoReady) return;
    if (state == AppLifecycleState.resumed) {
      unawaited(_resumeVideo());
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      unawaited(_controller!.pause());
    }
  }

  Future<void> _resumeVideo() async {
    try {
      if (_visualClock.elapsed >= SplashVideoScreen.visualDuration) {
        _expire();
      } else if (_canPlay && !_controller!.value.isCompleted) {
        await _controller!.play();
      }
    } catch (_) {
      _retireVideo();
      if (mounted) setState(() => _videoReady = false);
    }
  }

  Future<void> _enterImmersiveMode() async {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    if (!mounted || _systemUiRestored) return;
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarDividerColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        systemNavigationBarIconBrightness: Brightness.light,
        systemNavigationBarContrastEnforced: false,
      ),
    );
  }

  Future<void> _restoreSystemUi() async {
    if (kIsWeb || _systemUiRestored) return;
    _systemUiRestored = true;
    await SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: SystemUiOverlay.values,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _deadlineTimer?.cancel();
    _fadeTimer?.cancel();
    _visualClock.stop();
    _retireVideo();
    unawaited(_restoreSystemUi());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      textDirection: TextDirection.ltr,
      children: [
        // This element stays at the same key/index when the cover disappears.
        KeyedSubtree(
          key: const ValueKey('startup-destination'),
          child: _destination ?? const SizedBox.expand(),
        ),
        if (_visible)
          Positioned.fill(
            child: BlockSemantics(
              child: AbsorbPointer(
                child: AnimatedOpacity(
                  key: const ValueKey('startup-cover'),
                  opacity: _fading ? 0 : 1,
                  duration: SplashVideoScreen.fadeDuration,
                  curve: Curves.easeOut,
                  child: ColoredBox(
                    color: SplashVideoScreen.background,
                    child: Stack(
                      fit: StackFit.expand,
                      textDirection: TextDirection.ltr,
                      children: [
                        Image.asset(
                          SplashVideoScreen.posterPath,
                          fit: BoxFit.contain,
                          excludeFromSemantics: true,
                          errorBuilder: (_, __, ___) => const SizedBox.expand(),
                        ),
                        if (_videoReady && !_videoRetired)
                          FittedBox(
                            key: const ValueKey('splash-video-contain'),
                            fit: BoxFit.contain,
                            child: SizedBox(
                              width: _controller!.value.size.width,
                              height: _controller!.value.size.height,
                              child: VideoPlayer(_controller!),
                            ),
                          ),
                        const SplashBrand(),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// A localized elliptical light, with no expensive blur or repeating animation.
class SplashBrand extends StatelessWidget {
  const SplashBrand({super.key});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final width = (constraints.maxWidth * 0.82).clamp(0.0, 520.0);
      final fontSize = (constraints.maxWidth * 0.065).clamp(20.0, 38.0);
      final reduceMotion =
          MediaQuery.maybeOf(context)?.disableAnimations ?? false;
      return Center(
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: reduceMotion ? 1 : 0, end: 1),
          duration:
              reduceMotion ? Duration.zero : const Duration(milliseconds: 600),
          curve: Curves.easeOutCubic,
          builder: (context, value, child) => Opacity(
            opacity: value,
            child: Transform.translate(
              offset: Offset(0, (1 - value) * 8),
              child: child,
            ),
          ),
          child: RepaintBoundary(
            child: SizedBox(
              width: width,
              height: fontSize * 3.5,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    colors: [
                      AppTheme.primary.withValues(alpha: 0.52),
                      AppTheme.primaryDeep.withValues(alpha: 0.22),
                      AppTheme.primaryDeep.withValues(alpha: 0),
                    ],
                    stops: const [0, 0.4, 1],
                    transform: const _EllipticalGlow(),
                  ),
                ),
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        'delivery-mat3mk',
                        textDirection: TextDirection.ltr,
                        maxLines: 1,
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontFamilyFallback: AppTheme.fallbackFonts,
                          fontSize: fontSize,
                          height: 1.25,
                          fontWeight: FontWeight.w800,
                          color: AppTheme.background,
                          decoration: TextDecoration.none,
                          shadows: const [
                            Shadow(color: Color(0xB31A1A1A), blurRadius: 7),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    });
  }
}

class _EllipticalGlow extends GradientTransform {
  const _EllipticalGlow();

  @override
  Matrix4 transform(Rect bounds, {TextDirection? textDirection}) {
    final scale = bounds.width / bounds.height;
    return Matrix4.diagonal3Values(scale, 1, 1)
      ..setTranslationRaw(bounds.center.dx * (1 - scale), 0, 0);
  }
}
