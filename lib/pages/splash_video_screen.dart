import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import 'splash_screen_builders.dart';

class SplashVideoScreen<T> extends StatefulWidget {
  const SplashVideoScreen({
    super.key,
    required this.initialization,
    required this.destinationBuilder,
    required this.errorBuilder,
  });

  static const assetPath = 'assets/videos/splash.mp4';
  static const fadeDuration = Duration(milliseconds: 300);
  static const _graphite = Color(0xFF0E0F10);

  final Future<T> initialization;
  final SplashDestinationBuilder<T> destinationBuilder;
  final SplashErrorBuilder errorBuilder;

  @override
  State<SplashVideoScreen<T>> createState() => _SplashVideoScreenState<T>();
}

class _SplashVideoScreenState<T> extends State<SplashVideoScreen<T>>
    with WidgetsBindingObserver {
  late final VideoPlayerController _controller;
  T? _initializationResult;
  Object? _initializationError;
  StackTrace? _initializationStackTrace;
  bool _videoInitialized = false;
  bool _videoFinished = false;
  bool _initializationFinished = false;
  bool _navigating = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_enterImmersiveMode());
    unawaited(_initializeApp());
    unawaited(_initializeVideo());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.removeListener(_handleVideoUpdate);
    _controller.dispose();
    unawaited(_restoreSystemUi());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_videoInitialized || _videoFinished || _navigating) {
      return;
    }
    if (state == AppLifecycleState.resumed) {
      unawaited(_controller.play());
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      unawaited(_controller.pause());
    }
  }

  Future<void> _initializeApp() async {
    try {
      final result = await widget.initialization;
      if (!mounted) {
        return;
      }
      _initializationResult = result;
    } catch (error, stackTrace) {
      if (!mounted) {
        return;
      }
      _initializationError = error;
      _initializationStackTrace = stackTrace;
    }
    _initializationFinished = true;
    _maybeNavigate();
  }

  Future<void> _initializeVideo() async {
    _controller = VideoPlayerController.asset(
      SplashVideoScreen.assetPath,
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
    );
    _controller.addListener(_handleVideoUpdate);

    try {
      await _controller.initialize();
      if (!mounted) {
        return;
      }
      await _controller.setLooping(false);
      await _controller.setVolume(0);
      await _controller.play();
      if (!mounted) {
        return;
      }
      setState(() {
        _videoInitialized = true;
      });
      _handleVideoUpdate();
    } catch (_) {
      if (!mounted) {
        return;
      }
      _videoFinished = true;
      _maybeNavigate();
    }
  }

  void _handleVideoUpdate() {
    if (!mounted || _videoFinished) {
      return;
    }

    final value = _controller.value;
    if (value.hasError) {
      _videoFinished = true;
      _maybeNavigate();
      return;
    }

    final duration = value.duration;
    final completedByPosition = value.isInitialized &&
        duration > Duration.zero &&
        value.position >= duration - const Duration(milliseconds: 40);

    if (value.isCompleted || completedByPosition) {
      _videoFinished = true;
      unawaited(_controller.pause());
      _maybeNavigate();
    }
  }

  void _maybeNavigate() {
    if (!mounted ||
        _navigating ||
        !_videoFinished ||
        !_initializationFinished) {
      return;
    }

    _navigating = true;
    final result = _initializationResult;
    final error = _initializationError;
    final stackTrace = _initializationStackTrace;

    Navigator.of(context).pushReplacement(
      PageRouteBuilder<void>(
        transitionDuration: SplashVideoScreen.fadeDuration,
        reverseTransitionDuration: SplashVideoScreen.fadeDuration,
        pageBuilder: (context, animation, secondaryAnimation) {
          if (error != null) {
            return widget.errorBuilder(
              context,
              error,
              stackTrace ?? StackTrace.current,
            );
          }
          return widget.destinationBuilder(context, result as T);
        },
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          final curvedAnimation = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
          );
          return FadeTransition(
            opacity: curvedAnimation,
            child: child,
          );
        },
      ),
    );
  }

  Future<void> _enterImmersiveMode() async {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
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
    await SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: SystemUiOverlay.values,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: false,
      backgroundColor: SplashVideoScreen._graphite,
      body: _buildVideoViewport(),
    );
  }

  Widget _buildVideoViewport() {
    if (!_videoInitialized || !_controller.value.isInitialized) {
      return const SizedBox.expand(
        child: ColoredBox(color: SplashVideoScreen._graphite),
      );
    }

    final size = _controller.value.size;
    return SizedBox.expand(
      child: ColoredBox(
        color: SplashVideoScreen._graphite,
        child: ClipRect(
          child: FittedBox(
            fit: BoxFit.cover,
            alignment: Alignment.center,
            child: SizedBox(
              width: size.width,
              height: size.height,
              child: VideoPlayer(_controller),
            ),
          ),
        ),
      ),
    );
  }
}
