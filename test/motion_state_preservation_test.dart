import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:restaurant_customer/cart/cart_provider.dart';
import 'package:restaurant_customer/core/theme/app_theme.dart';
import 'package:restaurant_customer/core/localization/app_localizations.dart';
import 'package:restaurant_customer/core/stability/security_event_service.dart';
import 'package:restaurant_customer/core/stability/stability_metrics_service.dart';
import 'package:restaurant_customer/services/session_manager.dart';
import 'package:restaurant_customer/widgets/restaurant_card_components.dart';
import 'package:restaurant_customer/widgets/restaurants_grid_section.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('navigation preserves real cart, local session and scroll state',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    var requests = 0;
    await tester.runAsync(() async {
      await Supabase.initialize(
        url: 'https://motion-test.invalid',
        publishableKey: 'local-test-placeholder',
        httpClient: MockClient((request) async {
          requests++;
          expect(request.url.host, 'motion-test.invalid');
          return http.Response('[]', 200,
              request: request, headers: {'content-type': 'application/json'});
        }),
        authOptions: const FlutterAuthClientOptions(
          autoRefreshToken: false,
          detectSessionInUri: false,
          persistSession: false,
        ),
      );
      // In-memory fixture only: no credentials or requests reach a backend.
      final expiry = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
      String segment(Map<String, Object> value) =>
          base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
      final fixtureToken = '${segment({'alg': 'HS256', 'typ': 'JWT'})}.'
          '${segment({'sub': 'motion-test-user', 'exp': expiry})}.fixture';
      await Supabase.instance.client.auth.recoverSession(jsonEncode({
        'access_token': fixtureToken,
        'refresh_token': 'local-fixture-only',
        'token_type': 'bearer',
        'expires_at': expiry,
        'expires_in': 3600,
        'user': {
          'id': 'motion-test-user',
          'aud': 'authenticated',
          'app_metadata': <String, Object>{},
          'user_metadata': <String, Object>{},
          'created_at': '2026-01-01T00:00:00Z',
        },
      }));
    });
    final session = Supabase.instance.client.auth.currentSession;
    final scroll = ScrollController();
    final navigator = GlobalKey<NavigatorState>();
    // The real controller restores the authenticated fixture. Track resources
    // created by this fixture without changing application service lifetimes.
    final periodicTimers = <Timer>[];
    final cart = runZoned(
      CartController.new,
      zoneSpecification: ZoneSpecification(
        createPeriodicTimer: (self, parent, zone, duration, callback) {
          final timer = parent.createPeriodicTimer(zone, duration, callback);
          periodicTimers.add(timer);
          return timer;
        },
      ),
    );
    CartController? observedCart;
    var disposed = false;
    Future<void> disposeFixture() async {
      if (disposed) return;
      disposed = true;
      await tester.pumpWidget(const SizedBox.shrink());
      cart.dispose();
      scroll.dispose();
      try {
        await SessionManager.instance.dispose();
        await SecurityEventService.instance.dispose();
        await StabilityMetricsService.instance.dispose();
      } finally {
        // SessionSecurityService currently has no dispose API for its periodic
        // revocation fallback; cancel only timers created inside this fixture.
        for (final timer in periodicTimers) {
          timer.cancel();
        }
        await tester.runAsync(() => Supabase.instance.dispose());
      }
    }

    addTearDown(disposeFixture);

    await tester.pumpWidget(CartProvider(
      controller: cart,
      child: MaterialApp(
        navigatorKey: navigator,
        theme: AppTheme.light(),
        home: Builder(builder: (context) {
          observedCart = CartProvider.of(context);
          return Scaffold(
            body: ListView.builder(
              controller: scroll,
              itemExtent: 60,
              itemCount: 40,
              itemBuilder: (_, index) => Text('row $index'),
            ),
          );
        }),
      ),
    ));
    await tester.pumpAndSettle();
    cart.addItem(
      id: 'local-item',
      name: 'Local item',
      price: 25,
      image: '',
      restaurantId: 'local-restaurant',
    );
    cart.incrementItem('local-item');
    scroll.jumpTo(600);
    await tester.pumpAndSettle();
    final requestsBeforeNavigation = requests;
    final originalCart = observedCart;

    final result = navigator.currentState!.push<int>(
      AppTheme.platformPageRoute<int>(
        builder: (_) => const Scaffold(body: Text('destination')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('destination'), findsOneWidget);
    navigator.currentState!.pop(7);
    await tester.pumpAndSettle();

    expect(await result, 7);
    expect(identical(observedCart, originalCart), isTrue);
    expect(identical(observedCart, cart), isTrue);
    expect(cart.totalCount, 2);
    expect(cart.totalPrice, 50);
    expect(cart.restaurantId, 'local-restaurant');
    expect(scroll.offset, 600);
    expect(identical(Supabase.instance.client.auth.currentSession, session),
        isTrue);
    expect(requests, requestsBeforeNavigation);

    await disposeFixture();
  });

  testWidgets('restaurant content does not replay entry on parent rebuild',
      (tester) async {
    final search = ValueNotifier('');
    final rebuild = ValueNotifier(0);
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('ar'),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      theme: AppTheme.light(),
      home: Scaffold(
        body: ValueListenableBuilder<int>(
          valueListenable: rebuild,
          builder: (_, value, child) => RestaurantsGridSection(
            loading: false,
            hasError: false,
            restaurants: const [
              {'id': 'local-restaurant', 'name': 'Restaurant'}
            ],
            searchQueryListenable: search,
            onRefresh: () async {},
            emptyStateBuilder: (_) => const Text('empty'),
            errorStateBuilder: (_) => const Text('error'),
            onRestaurantTap: (_, restaurant) {},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    final entry =
        find.byKey(const ValueKey('restaurant-entry-local-restaurant'));
    final originalElement = tester.element(entry);
    rebuild.value++;
    await tester.pump();
    expect(identical(tester.element(entry), originalElement), isTrue);
    final opacity = tester.widget<Opacity>(find
        .descendant(
          of: entry,
          matching: find.byType(Opacity),
        )
        .first);
    expect(opacity.opacity, 1);
    search.value = 'no matching restaurant';
    await tester.pumpAndSettle();
    expect(entry, findsNothing);
    search.value = '';
    await tester.pump();
    expect(
        tester
            .widget<Opacity>(find
                .descendant(
                  of: entry,
                  matching: find.byType(Opacity),
                )
                .first)
            .opacity,
        1,
        reason: 'Filtering must not replay a previously entered card');
    await tester.pumpWidget(const SizedBox.shrink());
    search.dispose();
    rebuild.dispose();
  });

  testWidgets('restaurant presses respect reduced motion and stay tappable',
      (tester) async {
    var taps = 0;
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('ar'),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: MediaQuery(
        data: const MediaQueryData(
          size: Size(800, 600),
          disableAnimations: true,
        ),
        child: Scaffold(
            body: Center(
                child: SizedBox(
          width: 360,
          child: RestaurantListCard(
            name: 'Restaurant',
            imageUrl: '',
            deliveryMinutes: null,
            categoryLabel: null,
            distanceLabel: null,
            statusLabel: 'Open',
            statusPositive: true,
            onTap: () => taps++,
          ),
        ))),
      ),
    ));
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Restaurant')),
    );
    await tester.pump(const Duration(milliseconds: 150));
    final scale = tester.widget<AnimatedScale>(find
        .descendant(
          of: find.byType(RestaurantListCard),
          matching: find.byType(AnimatedScale),
        )
        .first);
    expect(scale.scale, 1);
    expect(scale.duration, Duration.zero);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(taps, 1);
  });
}
