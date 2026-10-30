import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:restaurant_customer/core/localization/app_localizations.dart';
import 'package:restaurant_customer/core/theme/app_theme.dart';
import 'package:restaurant_customer/services/restaurants_service.dart';
import 'package:restaurant_customer/widgets/restaurant_info_sheet.dart';

const _first = <String, dynamic>{
  'restaurant_id': 'restaurant-a',
  'manager_id': 'manager-a',
  'name': 'المطعم الأول',
  'open_time': '09:30:00',
  'close_time': '23:15:00',
  'address': null,
  'full_address': 'العنوان الكامل الأول',
};
const _second = <String, dynamic>{
  'restaurant_id': 'restaurant-b',
  'manager_id': 'manager-b',
  'name': 'المطعم الثاني',
  'open_time': '11:00:00',
  'close_time': '22:00:00',
  'address': 'عنوان المطعم الثاني',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  var rows = <Map<String, dynamic>>[];
  var rpcCalls = 0;
  Completer<http.Response>? pending;

  http.Response response(List<Map<String, dynamic>> data,
          {http.BaseRequest? request}) =>
      http.Response(
        jsonEncode(data),
        200,
        headers: {'content-type': 'application/json'},
        request: request,
      );

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'https://restaurant-info-test.invalid',
      publishableKey: 'local-fixture-only',
      // Lifecycle tests must not start a real auth refresh timer in FakeAsync.
      authOptions: const FlutterAuthClientOptions(
        autoRefreshToken: false,
        persistSession: false,
        detectSessionInUri: false,
      ),
      httpClient: MockClient((request) async {
        // A customer must never try to bypass the nearby RPC with a direct
        // managers/location request: those tables are staff-only under RLS.
        expect(request.url.host, 'restaurant-info-test.invalid');
        expect(request.url.path, '/rest/v1/rpc/get_nearby_restaurants');
        expect(jsonDecode(request.body), {'user_lat': 30.1, 'user_lng': 31.2});
        rpcCalls++;
        final delayed = pending;
        if (delayed != null) {
          final result = await delayed.future;
          return http.Response(result.body, result.statusCode,
              headers: result.headers, request: request);
        }
        return response(rows, request: request);
      }),
    );
  });

  tearDownAll(() async => Supabase.instance.dispose());

  setUp(() {
    rows = [Map<String, dynamic>.from(_first)];
    rpcCalls = 0;
    pending = null;
  });

  Future<void> open(
    WidgetTester tester, {
    Map<String, dynamic> restaurant = _first,
    bool refresh = true,
    ThemeMode mode = ThemeMode.light,
  }) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: mode,
      locale: const Locale('ar'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showRestaurantInfoSheet(
              context,
              restaurant: restaurant,
              customerLatitude: refresh ? 30.1 : null,
              customerLongitude: refresh ? 31.2 : null,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    if (refresh && pending == null) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      });
      await tester.pumpAndSettle();
    }
  }

  Future<void> close(WidgetTester tester) async {
    Navigator.of(tester.element(find.byType(RefreshIndicator))).pop();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  test('canonical times and alternate addresses handle blank/null values', () {
    expect(
        RestaurantsService.openingTimeOf({
          'open_time': '09:30:00',
          'opening_time': '16:00',
        }),
        '09:30');
    expect(
        RestaurantsService.closingTimeOf({
          'close_time': ' ',
          'closing_time': '23:15:00',
        }),
        '23:15');
    expect(
        RestaurantsService.restaurantAddressOf({
          'address': 'null',
          'full_address': ' ',
          'location_address': 'موقع المطعم',
        }),
        'موقع المطعم');
    expect(
        RestaurantsService.restaurantAddressOf({
          'street': 'شارع الاختبار',
          'city': 'القاهرة',
        }),
        'شارع الاختبار - القاهرة');
    expect(
        RestaurantsService.openingTimeOf({}, fallback: 'missing'), 'missing');
    expect(RestaurantsService.restaurantAddressOf({}, fallback: 'missing'),
        'missing');
  });

  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('authorized snapshot appears during refresh, RTL $mode',
        (tester) async {
      pending = Completer<http.Response>();
      await open(tester, mode: mode);
      expect(find.text('09:30'), findsOneWidget);
      expect(find.text('23:15'), findsOneWidget);
      expect(find.text('العنوان الكامل الأول'), findsOneWidget);
      expect(rpcCalls, 1);
      expect(Directionality.of(tester.element(find.text('09:30'))),
          TextDirection.rtl);
      pending!.complete(response([_first]));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      });
      await tester.pumpAndSettle();
      await close(tester);
    });
  }

  testWidgets('refresh selects restaurant_id rather than manager or first row',
      (tester) async {
    rows = [
      Map<String, dynamic>.from(_second),
      {..._first, 'open_time': '10:45:00', 'full_address': 'عنوان محدث'},
    ];
    await open(tester);
    expect(find.text('10:45'), findsOneWidget);
    expect(find.text('عنوان محدث'), findsOneWidget);
    expect(find.text('المطعم الثاني'), findsNothing);
    expect(find.text('عنوان المطعم الثاني'), findsNothing);
    expect(rpcCalls, 1);
    await close(tester);
  });

  testWidgets(
      'resume refreshes changed facts and authoritative null clears them',
      (tester) async {
    await open(tester);
    rows = [
      {..._first, 'open_time': null, 'full_address': null, 'close_time': null},
    ];
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    Supabase.instance.client.auth.stopAutoRefresh();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    });
    await tester.pumpAndSettle();
    expect(find.text('غير محدد'), findsNWidgets(3));
    expect(find.text('العنوان الكامل الأول'), findsNothing);
    expect(rpcCalls, 2);
    await close(tester);
  });

  testWidgets('pending refresh coalesces and clears facts for ineligible venue',
      (tester) async {
    pending = Completer<http.Response>();
    await open(tester);
    final refresh =
        tester.widget<RefreshIndicator>(find.byType(RefreshIndicator));
    final firstRefresh = refresh.onRefresh();
    final duplicateRefresh = refresh.onRefresh();
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    });
    expect(rpcCalls, 1);
    pending!.complete(response([_second]));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    });
    await tester.pumpAndSettle();
    await firstRefresh;
    await duplicateRefresh;
    expect(find.text('بيانات المطعم غير متاحة حاليًا'), findsNWidgets(3));
    expect(find.text('العنوان الكامل الأول'), findsNothing);
    expect(find.text('عنوان المطعم الثاني'), findsNothing);
    await close(tester);
  });

  testWidgets('switching sheets cannot apply a previous restaurant response',
      (tester) async {
    pending = Completer<http.Response>();
    await open(tester);
    final oldRequest = pending!;
    final oldRefresh = tester
        .widget<RefreshIndicator>(find.byType(RefreshIndicator))
        .onRefresh();
    await close(tester);
    pending = null;
    rows = [Map<String, dynamic>.from(_second)];
    await open(tester, restaurant: _second);
    oldRequest.complete(response([_first]));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    });
    await tester.pumpAndSettle();
    await oldRefresh;
    expect(find.text('المطعم الثاني'), findsOneWidget);
    expect(find.text('عنوان المطعم الثاني'), findsOneWidget);
    expect(find.text('العنوان الكامل الأول'), findsNothing);
    await close(tester);
  });

  testWidgets('snapshot-only callers do not make an unauthorized details query',
      (tester) async {
    await open(tester, refresh: false);
    expect(find.text('العنوان الكامل الأول'), findsOneWidget);
    expect(rpcCalls, 0);
    await close(tester);
  });
}

