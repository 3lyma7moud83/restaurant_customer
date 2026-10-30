import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:restaurant_customer/core/theme/app_theme.dart';
import 'package:restaurant_customer/core/ui/app_motion.dart';

const _capture = Key('route-capture');
const _home = Key('route-home');
const _page = Key('route-destination');

Widget _screen(Key key, Color color, String name) => Scaffold(
      key: key,
      backgroundColor: color,
      body: Center(child: Text(name)),
    );

Widget _host(GlobalKey<NavigatorState> navigator,
        {TextDirection direction = TextDirection.rtl, bool reduced = false}) =>
    RepaintBoundary(
      key: _capture,
      child: MaterialApp(
        navigatorKey: navigator,
        theme: AppTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
          child: Directionality(textDirection: direction, child: child!),
        ),
        home: _screen(_home, Colors.blue, 'Home'),
      ),
    );

Future<List<int>> _pixels(WidgetTester tester, String label) async {
  final boundary =
      tester.renderObject<RenderRepaintBoundary>(find.byKey(_capture));
  return (await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: .5);
    try {
      final pixels = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (const bool.fromEnvironment('CAPTURE_MOTION')) {
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        // Test artifact only; no application data or network traffic.
        // ignore: avoid_print
        print('MOTION_FRAME $label ${base64Encode(png!.buffer.asUint8List())}');
      }
      return pixels!.buffer.asUint8List().toList();
    } finally {
      image.dispose();
    }
  }))!;
}

void main() {
  for (final direction in TextDirection.values) {
    for (final motion in AppRouteMotion.values) {
      testWidgets('visible push and reverse frames: $direction $motion',
          (tester) async {
        final navigator = GlobalKey<NavigatorState>();
        await tester.pumpWidget(_host(navigator, direction: direction));
        await tester.pumpAndSettle();
        final original = tester.element(find.byKey(_home));
        final before =
            await _pixels(tester, '${direction.name}_${motion.name}_0');
        final route = AppTheme.platformPageRoute<String>(
          motion: motion,
          builder: (_) => _screen(_page, Colors.orange, 'Destination'),
        );
        final result = navigator.currentState!.push(route);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 75));
        final entering = tester.getTopLeft(find.byKey(_page)).dx;
        final outgoing = tester.getTopLeft(find.byKey(_home)).dx;
        final sign = direction == TextDirection.rtl ? -1 : 1;
        expect(entering * sign, inExclusiveRange(8, 64),
            reason: 'A small, measurable slide must still be visible at 75ms.');
        expect(outgoing * sign, lessThan(-1),
            reason:
                'The initial Home route must participate in the transition.');
        final fades = tester.widgetList<FadeTransition>(find.ancestor(
            of: find.byKey(_page), matching: find.byType(FadeTransition)));
        expect(fades.any((fade) => fade.opacity.value < .85), isTrue,
            reason:
                'A 0.94-to-1 fade is too subtle to establish a visible fade.');
        final forward =
            await _pixels(tester, '${direction.name}_${motion.name}_push75');
        await tester.pumpAndSettle();
        expect(tester.getTopLeft(find.byKey(_page)).dx, closeTo(0, .01));
        final settled =
            await _pixels(tester, '${direction.name}_${motion.name}_settled');
        expect(forward, isNot(equals(before)));
        expect(forward, isNot(equals(settled)),
            reason:
                'The rendered intermediate frame must differ from both endpoints.');
        navigator.currentState!.pop('kept-result');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 75));
        final leaving = tester.getTopLeft(find.byKey(_page)).dx;
        expect(leaving * sign, greaterThan(1));
        final reverse =
            await _pixels(tester, '${direction.name}_${motion.name}_pop75');
        expect(reverse, isNot(equals(settled)));
        expect(reverse, isNot(equals(before)));
        await tester.pumpAndSettle();
        expect(await result, 'kept-result');
        expect(tester.element(find.byKey(_home)), same(original));
        expect(tester.getTopLeft(find.byKey(_home)).dx, closeTo(0, .01));
        expect(
            await _pixels(tester, '${direction.name}_${motion.name}_returned'),
            equals(before));
        expect(tester.takeException(), isNull);
        // ignore: avoid_print
        print('MOTION_VISIBLE ${direction.name}/${motion.name}: '
            'push75=$entering home75=$outgoing pop75=$leaving; '
            'rendered forward/reverse frames differ; Home restored');
      });
    }
  }

  testWidgets('replacement and stack reset animate before becoming first',
      (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(_host(navigator));
    await tester.pumpAndSettle();
    for (final reset in [false, true]) {
      final key = Key('replacement-$reset');
      final route = AppTheme.platformPageRoute<void>(
          builder: (_) => _screen(key, Colors.orange, 'Replacement $reset'));
      if (reset) {
        navigator.currentState!.pushAndRemoveUntil(route, (_) => false);
      } else {
        navigator.currentState!.pushReplacement(route);
      }
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 75));
      expect(tester.getTopLeft(find.byKey(key)).dx, lessThan(-8));
      await tester.pumpAndSettle();
      expect(navigator.currentState!.canPop(), isFalse);
      expect(tester.getTopLeft(find.byKey(key)).dx, closeTo(0, .01));
    }
    expect(tester.takeException(), isNull);
  });
}
