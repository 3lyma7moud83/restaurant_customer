import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:restaurant_customer/cart/cart_provider.dart';
import 'package:restaurant_customer/core/localization/app_localizations.dart';
import 'package:restaurant_customer/core/theme/app_theme.dart';
import 'package:restaurant_customer/core/ui/app_brand_glow.dart';
import 'package:restaurant_customer/pages/home_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  var requests = 0;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'https://home-theme-test.invalid',
      publishableKey: 'local-ui-test-placeholder',
      httpClient: MockClient((request) async {
        requests++;
        expect(request.url.host, 'home-theme-test.invalid');
        return http.Response('[]', 200,
            request: request, headers: {'content-type': 'application/json'});
      }),
      authOptions: const FlutterAuthClientOptions(
        autoRefreshToken: false,
        detectSessionInUri: false,
        persistSession: false,
      ),
    );
  });
  tearDownAll(() async => Supabase.instance.dispose());
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    for (final width in [320.0, 390.0, 1200.0]) {
      testWidgets('Home name keeps its type and localized glow: $mode/$width',
          (tester) async {
        tester.view.physicalSize = Size(width, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(_host(
          mode: mode,
          home: Scaffold(
            appBar: AppBar(title: HomeAppBarTitle(compact: width < 390)),
          ),
        ));
        await tester.pumpAndSettle();
        final title = find.text('Delivery Mat3mk');
        final glow = find.byKey(const ValueKey('home-name-glow'));
        expect(title, findsOneWidget);
        expect(glow, findsOneWidget);
        expect(tester.getRect(glow), tester.getRect(title),
            reason: 'Glow must not change the existing name layout');
        final text = tester.widget<Text>(title);
        final scheme = Theme.of(tester.element(title)).colorScheme;
        expect(text.style!.color, scheme.onSurface);
        expect(
          _contrast(text.style!.color!,
              Theme.of(tester.element(title)).appBarTheme.backgroundColor!),
          greaterThanOrEqualTo(4.5),
        );
        expect(text.style!.fontWeight, FontWeight.w900);
        expect(DefaultTextStyle.of(tester.element(title)).style.fontFamily,
            'Cairo');
        expect(
            text.style!.fontSize,
            width >= 900
                ? 19
                : width < 390
                    ? 15.2
                    : 16.8);
        final decoration = tester
            .widget<DecoratedBox>(find.descendant(
              of: glow,
              matching: find.byType(DecoratedBox),
            ))
            .decoration as BoxDecoration;
        expect(decoration.boxShadow!.first.color,
            AppTheme.primary.withValues(alpha: 0.10));
        expect(decoration.boxShadow!.first.blurRadius, 14);
        expect(decoration.boxShadow!.first.offset, const Offset(0, 8));
        expect(decoration.boxShadow![1].blurRadius, 9);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets(
      'cart shares original glow and count updates preserve cart on theme change',
      (tester) async {
    final cart = CartController();
    final mode = ValueNotifier(ThemeMode.light);
    var taps = 0;
    await tester.pumpWidget(CartProvider(
      controller: cart,
      child: ValueListenableBuilder<ThemeMode>(
        valueListenable: mode,
        builder: (_, value, child) => _host(mode: value, home: child!),
        child: Scaffold(
          body: Center(
            child: HomeCartAction(
              buttonExtent: 44,
              onTap: () async => taps++,
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    cart.addItem(
        id: 'local-item',
        name: 'Meal',
        price: 25,
        image: '',
        restaurantId: 'local-restaurant');
    await tester.pumpAndSettle();
    final action = find.byType(HomeCartAction);
    final shells = tester
        .widgetList<DecoratedBox>(find.descendant(
          of: action,
          matching: find.byType(DecoratedBox),
        ))
        .where((widget) =>
            widget.decoration is BoxDecoration &&
            (widget.decoration as BoxDecoration).gradient != null);
    expect(shells, hasLength(1));
    expect((shells.single.decoration as BoxDecoration).boxShadow,
        orderedEquals(AppBrandGlow.shadows));
    cart.incrementItem('local-item');
    await tester.pump();
    expect(find.text('2'), findsOneWidget);
    await tester.pumpAndSettle();
    await tester.pump();
    expect(find.text('1'), findsNothing);
    final requestsBeforeTheme = requests;
    final originalElement = tester.element(action);
    mode.value = ThemeMode.dark;
    await tester.pumpAndSettle();
    expect(tester.element(action), same(originalElement));
    expect(cart.totalCount, 2);
    expect(cart.totalPrice, 50);
    expect(requests, requestsBeforeTheme);
    final number = tester.widget<Text>(find.text('2'));
    expect(number.style!.color,
        Theme.of(tester.element(action)).colorScheme.onPrimary);
    expect(_contrast(number.style!.color!, AppTheme.primary),
        greaterThanOrEqualTo(4.5));
    await tester.tap(find.byIcon(Icons.shopping_bag_outlined));
    expect(taps, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    cart.dispose();
    mode.dispose();
  });

  testWidgets(
      'actual Drawer surfaces update together without refetch or scroll reset',
      (tester) async {
    tester.view.physicalSize = const Size(390, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final mode = ValueNotifier(ThemeMode.light);
    await tester.pumpWidget(ValueListenableBuilder<ThemeMode>(
      valueListenable: mode,
      builder: (_, value, child) => _host(mode: value, home: child!),
      child: Scaffold(
        appBar: AppBar(title: const HomeAppBarTitle()),
        drawer: HomeMainDrawer(client: Supabase.instance.client),
        body: const SizedBox.expand(),
      ),
    ));
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    final drawer = find.byType(HomeMainDrawer);
    final originalState = tester.state(drawer);
    void verifyDrawerColors() {
      final scheme = Theme.of(tester.element(drawer)).colorScheme;
      final card = tester
          .widget<Card>(find.byKey(const ValueKey('home-drawer-login-card')));
      expect(card.color, scheme.primaryContainer);
      final loginTile = tester.widget<ListTile>(find.descendant(
        of: find.byKey(const ValueKey('home-drawer-login-card')),
        matching: find.byType(ListTile),
      ));
      expect(loginTile.textColor, scheme.onPrimaryContainer);
      expect(loginTile.iconColor, scheme.onPrimaryContainer);
      final header = tester
          .widget<Container>(find.byKey(const ValueKey('home-drawer-header')));
      final gradient =
          (header.decoration as BoxDecoration).gradient! as LinearGradient;
      expect(gradient.colors,
          [scheme.primaryContainer, scheme.surfaceContainerHigh]);
      expect(
          tester
              .widget<CircleAvatar>(find.byType(CircleAvatar))
              .backgroundColor,
          scheme.surface);
      final drawerSurface = tester.widget<Material>(find
          .descendant(
            of: find.byType(Drawer),
            matching: find.byType(Material),
          )
          .first);
      expect(drawerSurface.color,
          Theme.of(tester.element(drawer)).drawerTheme.backgroundColor);
    }

    verifyDrawerColors();
    await tester.drag(find.byType(ListView), const Offset(0, -100));
    await tester.pumpAndSettle();
    final scroll = tester.state<ScrollableState>(find.descendant(
      of: drawer,
      matching: find.byType(Scrollable),
    ));
    final offset = scroll.position.pixels;
    expect(offset, greaterThan(0));
    final requestsBeforeTheme = requests;
    mode.value = ThemeMode.dark;
    await tester.pumpAndSettle();
    verifyDrawerColors();
    expect(tester.state(drawer), same(originalState));
    expect(scroll.position.pixels, offset);
    expect(requests, requestsBeforeTheme);
    expect(Supabase.instance.client.auth.currentSession, isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    mode.dispose();
  });

  testWidgets('cart count respects reduced motion without delaying updates',
      (tester) async {
    final cart = CartController();
    await tester.pumpWidget(CartProvider(
      controller: cart,
      child: _host(
        mode: ThemeMode.dark,
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Scaffold(
            body: Center(
              child: HomeCartAction(buttonExtent: 44, onTap: () async {}),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    cart.addItem(
      id: 'motion-item',
      name: 'Meal',
      price: 15,
      image: '',
      restaurantId: 'local-restaurant',
    );
    await tester.pump();
    cart.incrementItem('motion-item');
    await tester.pump();
    final switcher = tester.widget<AnimatedSwitcher>(find.descendant(
      of: find.byType(HomeCartAction),
      matching: find.byType(AnimatedSwitcher),
    ));
    expect(switcher.duration, Duration.zero);
    expect(find.text('2'), findsOneWidget);
    expect(find.text('1'), findsNothing);
    expect(cart.totalPrice, 30);
    await tester.pumpWidget(const SizedBox.shrink());
    cart.dispose();
  });
}

Widget _host({required ThemeMode mode, required Widget home}) => MaterialApp(
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: mode,
      locale: const Locale('en'),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    );

double _contrast(Color a, Color b) {
  final first = a.computeLuminance();
  final second = b.computeLuminance();
  return first > second
      ? (first + 0.05) / (second + 0.05)
      : (second + 0.05) / (first + 0.05);
}
