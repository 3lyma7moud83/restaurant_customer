import 'dart:async';

import 'package:flutter/material.dart';

import '../core/ui/web_startup_splash.dart';
import 'splash_screen_builders.dart';

class WebBootstrapScreen<T> extends StatefulWidget {
  const WebBootstrapScreen({
    super.key,
    required this.initialization,
    required this.destinationBuilder,
    required this.errorBuilder,
  });

  static const _graphite = Color(0xFF0E0F10);

  final Future<T> initialization;
  final SplashDestinationBuilder<T> destinationBuilder;
  final SplashErrorBuilder errorBuilder;

  @override
  State<WebBootstrapScreen<T>> createState() => _WebBootstrapScreenState<T>();
}

class _WebBootstrapScreenState<T> extends State<WebBootstrapScreen<T>> {
  T? _initializationResult;
  Object? _initializationError;
  StackTrace? _initializationStackTrace;
  bool _initializationFinished = false;
  bool _splashReadyNotified = false;

  @override
  void initState() {
    super.initState();
    unawaited(_initializeApp());
  }

  Future<void> _initializeApp() async {
    try {
      _initializationResult = await widget.initialization;
    } catch (error, stackTrace) {
      _initializationError = error;
      _initializationStackTrace = stackTrace;
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _initializationFinished = true;
    });
  }

  void _notifySplashReadyAfterFrame() {
    if (_splashReadyNotified) {
      return;
    }

    _splashReadyNotified = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      notifyWebStartupSplashReady();
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_initializationFinished) {
      return const ColoredBox(color: WebBootstrapScreen._graphite);
    }

    _notifySplashReadyAfterFrame();
    final error = _initializationError;
    if (error != null) {
      return widget.errorBuilder(
        context,
        error,
        _initializationStackTrace ?? StackTrace.current,
      );
    }

    return widget.destinationBuilder(context, _initializationResult as T);
  }
}
