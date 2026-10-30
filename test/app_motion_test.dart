import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:restaurant_customer/core/theme/app_theme.dart';
import 'package:restaurant_customer/core/ui/app_components.dart';
import 'package:restaurant_customer/core/ui/app_motion.dart';

Widget testApp({
  required Widget home,
  TextDirection direction = TextDirection.rtl,
  bool reduced = false,
  ThemeData? theme,
}) =>
    MaterialApp(
      theme: theme ?? AppTheme.light(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
        child: Directionality(textDirection: direction, child: child!),
      ),
      home: home,
    );

void main() {
  for (final direction in TextDirection.values) {
    testWidgets(
        'push/pop preserves state, scroll, arguments and result in $direction',
        (tester) async {
      final form = TextEditingController(text: 'saved address');
      final scroll = ScrollController();
      addTearDown(form.dispose);
      addTearDown(scroll.dispose);
      BuildContext? homeContext;
      final homeKey = GlobalKey();
      await tester.pumpWidget(testApp(
        direction: direction,
        home: Builder(builder: (context) {
          homeContext = context;
          return Scaffold(
            key: homeKey,
            body: ListView(
              controller: scroll,
              children: [
                TextField(controller: form),
                const SizedBox(height: 2000),
              ],
            ),
          );
        }),
      ));
      final originalState = homeKey.currentState;
      scroll.jumpTo(180);
      await tester.pump();
      expect(find.byType(CupertinoPageTransition), findsNothing);
      final route = AppTheme.platformPageRoute<String>(
        settings: const RouteSettings(name: '/checkout', arguments: 'kept'),
        builder: (context) => Scaffold(
          key: const Key('destination'),
          body: Center(
              child: TextButton(
            onPressed: () => Navigator.pop(context, 'confirmed'),
            child: const Text('Return'),
          )),
        ),
      );
      final result = Navigator.of(homeContext!).push(route);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      final left = tester.getTopLeft(find.byKey(const Key('destination'))).dx;
      expect(
          left, direction == TextDirection.rtl ? lessThan(0) : greaterThan(0));
      expect(route.settings.arguments, 'kept');
      expect(route.transitionDuration, AppMotion.pageDuration);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Return'));
      await tester.pumpAndSettle();
      expect(await result, 'confirmed');
      expect(identical(homeKey.currentState, originalState), isTrue);
      expect(form.text, 'saved address');
      expect(scroll.offset, 180);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('interactive swipe back can cancel and complete in $direction',
        (tester) async {
      BuildContext? homeContext;
      await tester.pumpWidget(testApp(
        direction: direction,
        home: Builder(builder: (context) {
          homeContext = context;
          return const Scaffold(body: Text('Home'));
        }),
      ));
      final route = AppTheme.platformPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Swipe page')),
      );
      Navigator.of(homeContext!).push(route);
      await tester.pumpAndSettle();
      final width =
          tester.view.physicalSize.width / tester.view.devicePixelRatio;
      final sign = direction == TextDirection.rtl ? -1.0 : 1.0;
      final edge = Offset(direction == TextDirection.rtl ? width - 1 : 1, 250);
      var gesture = await tester.startGesture(edge);
      await gesture.moveBy(Offset(sign * width * .12, 0),
          timeStamp: const Duration(milliseconds: 500));
      await tester.pump();
      expect(route.popGestureInProgress, isTrue);
      await tester.pump(const Duration(milliseconds: 500));
      await gesture.up(timeStamp: const Duration(milliseconds: 1000));
      await tester.pumpAndSettle();
      expect(find.text('Swipe page'), findsOneWidget);
      gesture = await tester.startGesture(edge);
      await gesture.moveBy(Offset(sign * width * .8, 0),
          timeStamp: const Duration(milliseconds: 500));
      await tester.pump();
      await gesture.up(timeStamp: const Duration(milliseconds: 700));
      await tester.pumpAndSettle();
      expect(find.text('Home'), findsOneWidget);
      expect(Navigator.of(homeContext!).canPop(), isFalse);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('reduced motion skips page, count, button and overlay animation',
      (tester) async {
    BuildContext? homeContext;
    await tester.pumpWidget(testApp(
      reduced: true,
      home: Builder(builder: (context) {
        homeContext = context;
        return Scaffold(
            body: Column(children: [
          AppButton(label: 'Tap', onPressed: () {}),
          const AppAnimatedCount(value: 2),
        ]));
      }),
    ));
    expect(AppMotion.overlayStyle(homeContext!).duration, Duration.zero);
    expect(find.byType(AnimatedSwitcher), findsNothing);
    final press = await tester.startGesture(tester.getCenter(find.text('Tap')));
    await tester.pump();
    expect(tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale, 1);
    await press.up();
    final route = AppTheme.platformPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Instant')));
    Navigator.of(homeContext!).push(route);
    await tester.pump();
    await tester.pump();
    expect(route.transitionDuration, Duration.zero);
    expect(find.text('Instant'), findsOneWidget);
    expect(find.byType(CupertinoPageTransition), findsNothing);
    Navigator.of(homeContext!).pop();
    await tester.pumpAndSettle();
    expect(find.text('Tap'), findsOneWidget);
  });

  testWidgets('PopScope keeps blocked pages on stack', (tester) async {
    BuildContext? homeContext;
    await tester.pumpWidget(testApp(home: Builder(builder: (context) {
      homeContext = context;
      return const Scaffold();
    })));
    final route = AppTheme.platformPageRoute<void>(
        builder: (_) => const PopScope(
              canPop: false,
              child: Scaffold(body: Text('Saving')),
            ));
    Navigator.of(homeContext!).push(route);
    await tester.pumpAndSettle();
    expect(route.popGestureEnabled, isFalse);
    await Navigator.of(homeContext!).maybePop();
    await tester.pumpAndSettle();
    expect(find.text('Saving'), findsOneWidget);
  });

  for (final reduced in [false, true]) {
    testWidgets(
        'dialog and sheet preserve results and dismissal rules (reduced=$reduced)',
        (tester) async {
      BuildContext? homeContext;
      await tester.pumpWidget(testApp(
          reduced: reduced,
          home: Builder(builder: (context) {
            homeContext = context;
            return const Scaffold(body: Text('Home'));
          })));
      final dialogResult = showDialog<bool>(
        context: homeContext!,
        barrierDismissible: false,
        animationStyle: AppMotion.overlayStyle(homeContext!),
        builder: (context) => AlertDialog(
          title: const Text('Confirm'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Accept'))
          ],
        ),
      );
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.text('Confirm'), findsOneWidget);
      await tester.tap(find.text('Accept'));
      await tester.pumpAndSettle();
      expect(await dialogResult, isTrue);
      final sheetResult = showModalBottomSheet<String>(
        context: homeContext!,
        isDismissible: false,
        enableDrag: false,
        useSafeArea: true,
        sheetAnimationStyle: AppMotion.overlayStyle(homeContext!),
        builder: (context) => SizedBox(
            height: 200,
            child: Center(
                child: TextButton(
              onPressed: () => Navigator.pop(context, 'address'),
              child: const Text('Choose'),
            ))),
      );
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(10, 10));
      await tester.drag(find.text('Choose'), const Offset(0, 160));
      await tester.pumpAndSettle();
      expect(find.text('Choose'), findsOneWidget);
      await tester.tap(find.text('Choose'));
      await tester.pumpAndSettle();
      expect(await sheetResult, 'address');
      expect(find.text('Home'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('count updates once and unchanged rebuild does not replay',
      (tester) async {
    late StateSetter update;
    var count = 1;
    await tester
        .pumpWidget(testApp(home: StatefulBuilder(builder: (context, setState) {
      update = setState;
      return Scaffold(body: AppAnimatedCount(value: count));
    })));
    await tester.pumpAndSettle();
    update(() => count = 2);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(find.text('1'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('1'), findsNothing);
    update(() {});
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  test('light and dark themes share motion on every supported platform', () {
    for (final theme in [AppTheme.light(), AppTheme.dark()]) {
      for (final platform in TargetPlatform.values) {
        final builder = theme.pageTransitionsTheme.builders[platform];
        expect(builder, isA<AppPageTransitionsBuilder>());
        expect(builder!.transitionDuration, AppMotion.pageDuration);
      }
    }
  });
}
