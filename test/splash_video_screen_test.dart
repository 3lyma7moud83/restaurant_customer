import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:restaurant_customer/pages/splash_video_screen.dart';
import 'package:video_player/video_player.dart';

void main() {
  const coverKey = ValueKey('startup-cover');
  const videoKey = ValueKey('splash-video-contain');

  testWidgets('ready destination is covered until exactly 2500 milliseconds',
      (tester) async {
    final controller = _FakeVideoController();
    var destinationBuilds = 0;
    await tester.pumpWidget(SplashVideoScreen<String>(
      initialization: Future.value('ready'),
      controllerFactory: () => controller,
      destinationBuilder: (_, result) {
        destinationBuilds++;
        return _page(result);
      },
      errorBuilder: (_, error, stack) => _page('error'),
    ));
    await tester.pump();

    expect(find.text('ready'), findsOneWidget);
    expect(find.byKey(coverKey), findsOneWidget);
    expect(destinationBuilds, 1);

    await tester.pump(const Duration(milliseconds: 2499));
    expect(find.byKey(coverKey), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.byKey(coverKey), findsNothing);
    expect(find.text('ready'), findsOneWidget);
    expect(controller.disposeCalls, 1);

    await tester.pump(const Duration(seconds: 5));
    expect(destinationBuilds, 1);
    expect(controller.playCalls, 1);
    expect(find.byKey(coverKey), findsNothing);
  });

  testWidgets(
      'slow bootstrap retains the poster without replay or early routing',
      (tester) async {
    final bootstrap = Completer<String>();
    final controller = _FakeVideoController();
    var destinationBuilds = 0;
    await tester.pumpWidget(SplashVideoScreen<String>(
      initialization: bootstrap.future,
      controllerFactory: () => controller,
      destinationBuilder: (_, result) {
        destinationBuilds++;
        return _page(result);
      },
      errorBuilder: (_, error, stack) => _page('error'),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 2500));

    expect(destinationBuilds, 0);
    expect(find.byKey(coverKey), findsOneWidget);
    expect(find.byKey(videoKey), findsNothing);
    expect(find.byType(Image), findsOneWidget);
    expect(controller.disposeCalls, 1);

    await tester.pump(const Duration(seconds: 4));
    expect(controller.playCalls, 1);
    bootstrap.complete('restored home');
    await tester.pumpAndSettle();
    expect(find.text('restored home'), findsOneWidget);
    expect(find.byKey(coverKey), findsNothing);
    expect(destinationBuilds, 1);
  });

  testWidgets('bootstrap failure reveals its error destination at the deadline',
      (tester) async {
    final bootstrap = Completer<String>();
    final controller = _FakeVideoController();
    final failure = StateError('bootstrap unavailable');
    Object? receivedError;
    await tester.pumpWidget(SplashVideoScreen<String>(
      initialization: bootstrap.future,
      controllerFactory: () => controller,
      destinationBuilder: (_, result) => _page('unexpected home'),
      errorBuilder: (_, error, stack) {
        receivedError = error;
        return _page('bootstrap error');
      },
    ));
    bootstrap.completeError(failure, StackTrace.current);
    await tester.pump();
    expect(identical(receivedError, failure), isTrue);
    expect(find.byKey(coverKey), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 2500));
    expect(find.byKey(coverKey), findsNothing);
    expect(find.text('bootstrap error'), findsOneWidget);
    expect(find.text('unexpected home'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final viewport in <Size>[
    const Size(390, 844),
    const Size(1200, 800),
  ]) {
    testWidgets(
        'silent one-shot video preserves full aspect ratio at $viewport',
        (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = viewport;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = _FakeVideoController();
      await tester.pumpWidget(_splash(controller));
      await tester.pump();

      expect(controller.configuredVolume, 0);
      expect(controller.configuredLooping, isFalse);
      expect(controller.configuredSpeed, closeTo(3.2, 0.1));
      expect(controller.playCalls, 1);
      expect(
          controller.calls.indexOf('volume'),
          lessThan(
            controller.calls.indexOf('play'),
          ));
      final fitted = tester.widget<FittedBox>(find.byKey(videoKey));
      expect(fitted.fit, BoxFit.contain);
      final visibleVideo = tester.getRect(find.byType(VideoPlayer));
      expect(
          visibleVideo.width / visibleVideo.height, closeTo(720 / 1280, 0.001));
      expect(visibleVideo.left, greaterThanOrEqualTo(-0.01));
      expect(visibleVideo.top, greaterThanOrEqualTo(-0.01));
      expect(visibleVideo.right, lessThanOrEqualTo(viewport.width + 0.01));
      expect(visibleVideo.bottom, lessThanOrEqualTo(viewport.height + 0.01));
      expect(find.text('delivery-mat3mk'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('decode failure falls back to poster and still dismisses on time',
      (tester) async {
    final controller = _FakeVideoController(failInitialize: true);
    await tester.pumpWidget(_splash(controller));
    await tester.pump();
    expect(find.byKey(videoKey), findsNothing);
    expect(find.byType(Image), findsOneWidget);
    expect(find.byKey(coverKey), findsOneWidget);
    expect(controller.playCalls, 0);
    await tester.pump(const Duration(milliseconds: 2500));
    expect(find.text('home'), findsOneWidget);
    expect(find.byKey(coverKey), findsNothing);
    expect(controller.disposeCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('play failure retains poster without delaying the destination',
      (tester) async {
    final controller = _FakeVideoController(failPlay: true);
    await tester.pumpWidget(_splash(controller));
    await tester.pump();
    expect(find.byKey(videoKey), findsNothing);
    expect(find.byType(Image), findsOneWidget);
    expect(controller.disposeCalls, 1);
    await tester.pump(const Duration(milliseconds: 2500));
    expect(find.byKey(coverKey), findsNothing);
    expect(find.text('home'), findsOneWidget);
    expect(controller.playCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('video initialization cannot start playback after the deadline',
      (tester) async {
    final initialize = Completer<void>();
    final controller = _FakeVideoController(initialization: initialize.future);
    await tester.pumpWidget(_splash(controller));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 2500));
    expect(find.byKey(coverKey), findsNothing);
    expect(controller.disposeCalls, 1);
    initialize.complete();
    await tester.pump();
    expect(controller.playCalls, 0);
    expect(controller.configuredSpeed, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('resume never replays a completed or retired startup video',
      (tester) async {
    final controller = _FakeVideoController();
    await tester.pumpWidget(_splash(controller));
    await tester.pump();
    controller.finishPlayback();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(controller.playCalls, 1);

    await tester.pump(const Duration(milliseconds: 2500));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(controller.playCalls, 1);
    expect(controller.disposeCalls, 1);
    expect(find.byKey(coverKey), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unmount during video initialization prevents late playback',
      (tester) async {
    final initialize = Completer<void>();
    final bootstrap = Completer<String>();
    final controller = _FakeVideoController(initialization: initialize.future);
    await tester
        .pumpWidget(_splash(controller, initialization: bootstrap.future));
    await tester.pumpWidget(const SizedBox.shrink());
    initialize.complete();
    bootstrap.complete('late home');
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));

    expect(controller.playCalls, 0);
    expect(controller.configuredVolume, isNull);
    expect(controller.disposeCalls, 1);
    expect(find.text('late home'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('startup cover blocks touches until it has fully disappeared',
      (tester) async {
    final controller = _FakeVideoController();
    var taps = 0;
    await tester.pumpWidget(SplashVideoScreen<void>(
      initialization: Future<void>.value(),
      controllerFactory: () => controller,
      destinationBuilder: (_, result) => MaterialApp(
        home: Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => taps++,
              child: const Text('open menu'),
            ),
          ),
        ),
      ),
      errorBuilder: (_, error, stack) => _page('error'),
    ));
    await tester.pump();
    final buttonCenter = tester.getCenter(find.text('open menu'));
    await tester.tapAt(buttonCenter);
    expect(taps, 0);
    await tester.pump(const Duration(milliseconds: 2400));
    await tester.tapAt(buttonCenter);
    expect(taps, 0);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tapAt(buttonCenter);
    expect(taps, 1);
  });

  testWidgets('queued route and navigator state survive startup cover removal',
      (tester) async {
    final controller = _FakeVideoController();
    final navigatorKey = GlobalKey<NavigatorState>();
    final probeKey = GlobalKey<_DestinationProbeState>();
    await tester.pumpWidget(SplashVideoScreen<String>(
      initialization: Future.value('ready'),
      controllerFactory: () => controller,
      destinationBuilder: (_, result) => _DestinationProbe(
        key: probeKey,
        navigatorKey: navigatorKey,
      ),
      errorBuilder: (_, error, stack) => _page('error'),
    ));
    await tester.pump();
    final originalNavigator = navigatorKey.currentState;
    final originalDestination = probeKey.currentState;
    unawaited(navigatorKey.currentState!.push<void>(
      MaterialPageRoute<void>(
          builder: (_) => const Scaffold(
                body: Center(child: Text('receipt 1234')),
              )),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('receipt 1234'), findsOneWidget);
    expect(find.byKey(coverKey), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 2200));
    expect(find.byKey(coverKey), findsNothing);
    expect(find.text('receipt 1234'), findsOneWidget);
    expect(identical(navigatorKey.currentState, originalNavigator), isTrue);
    expect(identical(probeKey.currentState, originalDestination), isTrue);
    expect(navigatorKey.currentState!.canPop(), isTrue);
    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);
    expect(find.byKey(coverKey), findsNothing);
  });

  final captureDirectory = Platform.environment['SPLASH_CAPTURE_DIR'];
  if (captureDirectory != null && captureDirectory.isNotEmpty) {
    for (final viewport in <Size>[
      const Size(390, 844),
      const Size(1200, 800),
    ]) {
      testWidgets('capture production poster and brand at $viewport',
          (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = viewport;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.runAsync(() async {
          final loader = FontLoader('Cairo')
            ..addFont(rootBundle.load('assets/fonts/Cairo-Regular.ttf'));
          await loader.load();
        });
        final screenshotKey = GlobalKey();
        await tester.pumpWidget(RepaintBoundary(
          key: screenshotKey,
          child: _splash(_FakeVideoController(failInitialize: true)),
        ));
        await tester.runAsync(() async {
          await precacheImage(
            const AssetImage(SplashVideoScreen.posterPath),
            tester.element(find.byType(SplashBrand)),
          );
        });
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pump();
        await tester.runAsync(() async {
          final boundary = screenshotKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory(captureDirectory).create(recursive: true);
          final output = File('$captureDirectory/splash_flutter_'
              '${viewport.width.toInt()}x${viewport.height.toInt()}.png');
          await output.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}

Widget _page(String label) => MaterialApp(
      home: Scaffold(body: Center(child: Text(label))),
    );

Widget _splash(
  _FakeVideoController controller, {
  Future<String>? initialization,
}) =>
    SplashVideoScreen<String>(
      initialization: initialization ?? Future.value('home'),
      controllerFactory: () => controller,
      destinationBuilder: (_, result) => _page(result),
      errorBuilder: (_, error, stack) => _page('error'),
    );

/// Keeps decoding/platform calls out of lifecycle and navigation regression
/// tests. Its real controller value still drives the production VideoPlayer.
class _FakeVideoController extends VideoPlayerController {
  _FakeVideoController({
    this.initialization,
    this.failInitialize = false,
    this.failPlay = false,
  }) : super.asset(SplashVideoScreen.assetPath);

  final Future<void>? initialization;
  final bool failInitialize;
  final bool failPlay;
  final List<String> calls = [];
  int playCalls = 0;
  int disposeCalls = 0;
  double? configuredVolume;
  double? configuredSpeed;
  bool? configuredLooping;

  @override
  Future<void> initialize() async {
    if (initialization != null) await initialization;
    if (failInitialize) throw StateError('decoder unavailable');
    if (disposeCalls > 0) return;
    value = const VideoPlayerValue(
      duration: Duration(seconds: 8),
      size: Size(720, 1280),
      isInitialized: true,
    );
  }

  @override
  Future<void> setLooping(bool looping) async {
    configuredLooping = looping;
    calls.add('loop');
    value = value.copyWith(isLooping: looping);
  }

  @override
  Future<void> setVolume(double volume) async {
    configuredVolume = volume;
    calls.add('volume');
    value = value.copyWith(volume: volume);
  }

  @override
  Future<void> setPlaybackSpeed(double speed) async {
    configuredSpeed = speed;
    calls.add('speed');
    value = value.copyWith(playbackSpeed: speed);
  }

  @override
  Future<void> play() async {
    playCalls++;
    calls.add('play');
    if (failPlay) throw StateError('playback unavailable');
    value = value.copyWith(isPlaying: true);
  }

  @override
  Future<void> pause() async {
    calls.add('pause');
    value = value.copyWith(isPlaying: false);
  }

  void finishPlayback() {
    value = value.copyWith(
      position: value.duration,
      isPlaying: false,
      isCompleted: true,
    );
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
    await super.dispose();
  }
}

class _DestinationProbe extends StatefulWidget {
  const _DestinationProbe({super.key, required this.navigatorKey});

  final GlobalKey<NavigatorState> navigatorKey;

  @override
  State<_DestinationProbe> createState() => _DestinationProbeState();
}

class _DestinationProbeState extends State<_DestinationProbe> {
  @override
  Widget build(BuildContext context) => MaterialApp(
        navigatorKey: widget.navigatorKey,
        home: const Scaffold(body: Center(child: Text('home'))),
      );
}
