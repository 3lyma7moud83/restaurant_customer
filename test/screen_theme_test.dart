import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:restaurant_customer/cart/cart_page.dart';
import 'package:restaurant_customer/cart/cart_provider.dart';
import 'package:restaurant_customer/core/localization/app_localizations.dart';
import 'package:restaurant_customer/core/stability/security_event_service.dart';
import 'package:restaurant_customer/core/stability/stability_metrics_service.dart';
import 'package:restaurant_customer/core/theme/app_theme.dart';
import 'package:restaurant_customer/pages/restaurant_menu_page.dart';
import 'package:restaurant_customer/services/session_manager.dart';
import 'package:restaurant_customer/services/profile_service.dart';

Widget _host(ValueNotifier<ThemeMode> mode, Widget child) =>
    ValueListenableBuilder<ThemeMode>(
      valueListenable: mode,
      builder: (context, themeMode, _) => MaterialApp(
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: themeMode,
        locale: const Locale('ar'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate
        ],
        home: child,
      ),
    );

void main() {
  for (final modeValue in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets(
        'item card and opened options use $modeValue and retain selection on theme change',
        (tester) async {
      final mode = ValueNotifier(modeValue);
      addTearDown(mode.dispose);
      const variants = [
        MenuItemVariant(id: 'small', name: 'Small', price: 25),
        MenuItemVariant(id: 'large', name: 'Large', price: 40)
      ];
      var adds = 0;
      MenuItemVariant? added;
      await tester.pumpWidget(_host(
          mode,
          Scaffold(
              body: Center(
                  child: SizedBox(
            width: 180,
            height: 184,
            child: ItemCard(
                itemId: 'theme-item',
                name: 'Theme item',
                basePrice: 25,
                imageUrl: '',
                variants: variants,
                onAdd: (variant) {
                  adds++;
                  added = variant;
                }),
          )))));
      await tester.pumpAndSettle();
      final item = find.byType(ItemCard);
      final itemSize = tester.getSize(item);
      final itemState = tester.state(item);
      void assertColors() {
        final scheme = Theme.of(tester.element(item)).colorScheme;
        final outer = tester.widget<DecoratedBox>(find
            .descendant(of: item, matching: find.byType(DecoratedBox))
            .first);
        expect((outer.decoration as BoxDecoration).color, scheme.surface);
        expect(tester.widget<Text>(find.text('Theme item')).style!.color,
            scheme.onSurface);
        final anchor = tester.widget<MenuAnchor>(find.byType(MenuAnchor));
        expect(anchor.style!.backgroundColor!.resolve({}), scheme.surface);
      }

      assertColors();
      await tester.tap(find.text('Small'));
      await tester.pumpAndSettle();
      expect(find.byType(MenuItemButton), findsNWidgets(2));
      final scheme = Theme.of(tester.element(item)).colorScheme;
      for (final option
          in tester.widgetList<MenuItemButton>(find.byType(MenuItemButton))) {
        final color = option.style!.backgroundColor!.resolve({});
        expect(color == scheme.surface || color == scheme.surfaceContainerHigh,
            isTrue);
        expect(option.style!.foregroundColor!.resolve({}), scheme.onSurface);
      }
      await tester.tap(find.text('Large').last);
      await tester.pumpAndSettle();
      expect(find.text('40 ج'), findsOneWidget);
      mode.value =
          modeValue == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
      await tester.pumpAndSettle();
      assertColors();
      expect(identical(tester.state(item), itemState), isTrue);
      expect(tester.getSize(item), itemSize);
      expect(find.text('Large'), findsOneWidget);
      expect(adds, 0);
      await tester.tap(find.byKey(const Key('menu-item-add-button')));
      expect(adds, 1);
      expect(added?.id, 'large');
      expect(added?.price, 40);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  group('real cart presentation with local-only authenticated fixture', () {
    var requests = 0;
    setUpAll(() async {
      SharedPreferences.setMockInitialValues({});
      await Supabase.initialize(
        url: 'https://theme-test.invalid',
        publishableKey: 'local-fixture-only',
        httpClient: MockClient((request) async {
          requests++;
          expect(request.url.host, 'theme-test.invalid');
          final body =
              request.method == 'GET' && request.url.path.endsWith('/customers')
                  ? jsonEncode([
                      {'name': 'Fixture customer', 'phone': '01000000000'}
                    ])
                  : '[]';
          return http.Response(body, 200,
              request: request, headers: {'content-type': 'application/json'});
        }),
        authOptions: const FlutterAuthClientOptions(
            autoRefreshToken: false,
            detectSessionInUri: false,
            persistSession: false),
      );
      final expiry = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
      String segment(Map<String, Object> value) =>
          base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
      // Synthetic in-memory session. Every HTTP request terminates in MockClient.
      final token = '${segment({'alg': 'HS256', 'typ': 'JWT'})}.${segment({
            'sub': 'theme-user',
            'exp': expiry
          })}.fixture';
      await Supabase.instance.client.auth.recoverSession(jsonEncode({
        'access_token': token,
        'refresh_token': 'fixture-only',
        'token_type': 'bearer',
        'expires_at': expiry,
        'expires_in': 3600,
        'user': {
          'id': 'theme-user',
          'aud': 'authenticated',
          'app_metadata': {},
          'user_metadata': {},
          'created_at': '2026-01-01T00:00:00Z'
        },
      }));
    });
    tearDownAll(() async {
      await SessionManager.instance.dispose();
      await Supabase.instance.dispose();
    });

    for (final modeValue in [ThemeMode.light, ThemeMode.dark]) {
      testWidgets(
          'cart inputs, quantity and confirmation dialog follow $modeValue without refetch',
          (tester) async {
        final periodicTimers = <Timer>[];
        final cart =
            runZoned(CartController.new, zoneSpecification: ZoneSpecification(
          createPeriodicTimer: (self, parent, zone, duration, callback) {
            final timer = parent.createPeriodicTimer(zone, duration, callback);
            periodicTimers.add(timer);
            return timer;
          },
        ));
        final mode = ValueNotifier(modeValue);
        try {
          await tester.pump();
          cart.clear();
          cart.addItem(
              id: 'theme-item',
              name: 'Theme cart item',
              price: 25,
              image: '',
              restaurantId: 'theme-restaurant');
          await tester.pumpWidget(CartProvider(
              controller: cart,
              child: _host(
                  mode, const CartPage(restaurantId: 'theme-restaurant'))));
          // PostgREST's JSON worker completes on the real event loop. Await a
          // fixture request before advancing the widget test's virtual clock.
          await tester.runAsync(() => ProfileService().getOrCreateProfile());
          await tester.pumpAndSettle();
          expect(find.text('Theme cart item'), findsOneWidget);
          final cartContext = tester.element(find.byType(CartPage));
          final scheme = Theme.of(cartContext).colorScheme;
          expect(
              tester
                  .widget<Scaffold>(find.byType(Scaffold).first)
                  .backgroundColor,
              Theme.of(cartContext).scaffoldBackgroundColor);
          expect(tester.widget<Text>(find.text('Theme cart item')).style!.color,
              scheme.onSurface);
          await tester.tap(find.byTooltip('زيادة الكمية'));
          await tester.pumpAndSettle();
          expect(cart.totalCount, 2);
          expect(cart.totalPrice, 50);
          await tester.enterText(
              find.byKey(const ValueKey('cart-item-note-theme-item')),
              'Keep this note');
          await tester.pumpAndSettle();
          final session = Supabase.instance.client.auth.currentSession;
          final before = requests;
          mode.value =
              modeValue == ThemeMode.light ? ThemeMode.dark : ThemeMode.light;
          await tester.pumpAndSettle();
          expect(requests, before);
          expect(cart.totalCount, 2);
          expect(cart.items.single.note, 'Keep this note');
          expect(
              identical(Supabase.instance.client.auth.currentSession, session),
              isTrue);
          final currentTheme = Theme.of(tester.element(find.byType(CartPage)));
          expect(tester.widget<Text>(find.text('Theme cart item')).style!.color,
              currentTheme.colorScheme.onSurface);
          await tester.tap(find.byTooltip('حذف الصنف'));
          await tester.pumpAndSettle();
          final dialog = find.byType(AlertDialog);
          expect(dialog, findsOneWidget);
          final dialogMaterials = tester.widgetList<Material>(
              find.descendant(of: dialog, matching: find.byType(Material)));
          expect(
              dialogMaterials.any((m) =>
                  m.color == currentTheme.dialogTheme.backgroundColor ||
                  m.color == currentTheme.colorScheme.surfaceContainerHigh),
              isTrue);
          await tester.tap(find.text('إلغاء'));
          await tester.pumpAndSettle();
          expect(cart.totalCount, 2);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox());
          cart.dispose();
          mode.dispose();
          await SecurityEventService.instance.dispose();
          await StabilityMetricsService.instance.dispose();
          for (final timer in periodicTimers) {
            timer.cancel();
          }
        }
      });
    }
  });
}
