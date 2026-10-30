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
import 'package:restaurant_customer/services/complaints_service.dart';
import 'package:restaurant_customer/widgets/restaurant_info_sheet.dart';

const _user = '10000000-0000-4000-8000-000000000001';
const _restaurant = '20000000-0000-4000-8000-000000000002';
const _otherRestaurant = '30000000-0000-4000-8000-000000000003';
const _order = '40000000-0000-4000-8000-000000000004';
const _title = 'شكوى اختبار محلية';
const _description = 'تفاصيل شكوى محلية لا تغادر عميل HTTP الوهمي.';

Future<void> _setSession(SupabaseClient client) async {
  final expiry = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
  String segment(Map<String, Object> value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  final token = '${segment({'alg': 'HS256', 'typ': 'JWT'})}.${segment({
        'sub': _user,
        'exp': expiry,
      })}.local-fixture';
  await client.auth.recoverSession(jsonEncode({
    'access_token': token,
    'refresh_token': 'local-fixture-only',
    'token_type': 'bearer',
    'expires_at': expiry,
    'expires_in': 3600,
    'user': {
      'id': _user,
      'aud': 'authenticated',
      'app_metadata': {},
      'user_metadata': {'name': 'عميل محلي'},
      'created_at': '2026-01-01T00:00:00Z'
    },
  }));
}

http.Response _response(http.Request request, Object? body,
        [int status = 200]) =>
    http.Response(jsonEncode(body), status,
        request: request, headers: {'content-type': 'application/json'});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SupabaseClient client;
  late ComplaintsService service;
  late Future<http.Response> Function(http.Request) handle;
  final requests = <http.Request>[];
  final rows = <String, Map<String, dynamic>>{};

  Future<http.Response> storage(http.Request request) async {
    expect(request.url.path, '/rest/v1/complaints');
    if (request.method == 'POST') {
      final payload = jsonDecode(request.body) as Map<String, dynamic>;
      final id = payload['id'] as String;
      if (rows.containsKey(id)) {
        return _response(
            request, {'code': '23505', 'message': 'duplicate key'}, 409);
      }
      rows[id] = payload;
      return _response(request, payload, 201);
    }
    expect(request.method, 'GET');
    expect(request.url.queryParameters['user_id'], 'eq.$_user');
    final id = request.url.queryParameters['id']!.substring(3);
    return _response(request, [if (rows[id] != null) rows[id]]);
  }

  Future<String> submit({String? restaurant = _restaurant, String? order}) =>
      service.submit(
          userId: _user,
          title: _title,
          description: _description,
          restaurantId: restaurant,
          orderId: order);

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'https://complaints-test.invalid',
      publishableKey: 'local-fixture-only',
      httpClient: MockClient((request) async {
        expect(request.url.host, 'complaints-test.invalid');
        requests.add(request);
        return handle(request);
      }),
      authOptions: const FlutterAuthClientOptions(
          autoRefreshToken: false,
          detectSessionInUri: false,
          persistSession: false),
    );
    client = Supabase.instance.client;
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    requests.clear();
    rows.clear();
    handle = storage;
    await _setSession(client);
    service = ComplaintsService(
        client: client,
        validateSession: () async => client.auth.currentSession);
  });
  tearDownAll(() => Supabase.instance.dispose());

  test(
      'confirmed INSERT uses actual schema, current user and selected restaurant',
      () async {
    final id = await service.submit(
        userId: _user,
        title: ' $_title ',
        description: ' $_description ',
        restaurantId: _restaurant);
    expect(requests, hasLength(1));
    expect(
        requests.single.headers['prefer'], contains('return=representation'));
    expect(rows[id], containsPair('user_id', _user));
    expect(rows[id], containsPair('restaurant_id', _restaurant));
    expect(rows[id], containsPair('complaint_title', _title));
    expect(rows[id], containsPair('complaint_message', _description));
    expect(rows[id], containsPair('customer_name', 'عميل محلي'));
    expect(
        rows[id]!.keys,
        unorderedEquals([
          'id',
          'user_id',
          'restaurant_id',
          'customer_name',
          'customer_phone',
          'complaint_title',
          'complaint_message'
        ]));
    expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
  });

  test('general complaint never guesses restaurant from recent order or cart',
      () async {
    final id = await submit(restaurant: null);
    expect(rows[id]!['restaurant_id'], isNull);
    expect(requests, hasLength(1));
  });

  test('missing validated session never reports success or writes', () async {
    service =
        ComplaintsService(client: client, validateSession: () async => null);
    await expectLater(submit(), throwsA(isA<ComplaintSubmissionException>()));
    expect(requests, isEmpty);
  });

  test('caller cannot submit as another user', () async {
    await expectLater(
        service.submit(
            userId: 'another-user',
            title: _title,
            description: _description,
            restaurantId: _restaurant),
        throwsA(isA<ComplaintSubmissionException>()));
    expect(requests, isEmpty);
  });

  test('invalid input and restaurant identity cause no request', () async {
    await expectLater(
        service.submit(userId: _user, title: 'a', description: _description),
        throwsA(isA<ComplaintSubmissionException>()));
    await expectLater(submit(restaurant: 'not-an-id'),
        throwsA(isA<ComplaintSubmissionException>()));
    expect(requests, isEmpty);
  });

  test('explicit order is scoped to current customer and matching restaurant',
      () async {
    handle = (request) async {
      if (request.url.path.endsWith('/orders')) {
        expect(request.url.queryParameters['customer_id'], 'eq.$_user');
        expect(request.url.queryParameters['id'], 'eq.$_order');
        return _response(request, [
          {'restaurant_id': _restaurant}
        ]);
      }
      return storage(request);
    };
    final id = await submit(order: _order);
    expect(rows[id]!['restaurant_id'], _restaurant);
    expect(rows[id]!.containsKey('order_id'), isFalse);
  });

  test('order from a different restaurant cannot be bound', () async {
    handle = (request) async => _response(request, [
          {'restaurant_id': _otherRestaurant}
        ]);
    await expectLater(
        submit(order: _order), throwsA(isA<ComplaintSubmissionException>()));
    expect(requests.where((r) => r.method == 'POST'), isEmpty);
  });

  for (final failure in ['42501', '42703']) {
    test('server failure $failure never falls back to a second INSERT',
        () async {
      handle = (request) async => _response(
          request, {'code': failure, 'message': 'rejected by server'}, 400);
      await expectLater(submit(), throwsA(isA<ComplaintSubmissionException>()));
      expect(requests, hasLength(1));
      expect(rows, isEmpty);
    });
  }

  test('simultaneous submissions coalesce into one confirmed record', () async {
    final gate = Completer<void>();
    handle = (request) async {
      await gate.future;
      return storage(request);
    };
    final first = submit();
    final second = submit();
    gate.complete();
    final ids = await Future.wait([first, second]);
    expect(ids[0], ids[1]);
    expect(rows, hasLength(1));
    expect(requests, hasLength(1));
  });

  test(
      'lost response persists pending ID; reopening reconciles without rewrite',
      () async {
    handle = (request) async {
      await storage(request);
      throw http.ClientException('local simulated response loss');
    };
    await expectLater(submit(), throwsA(isA<ComplaintSubmissionException>()));
    final pending = await SharedPreferences.getInstance();
    expect(pending.getKeys(), hasLength(1));
    expect(pending.getString(pending.getKeys().single), rows.keys.single);
    service = ComplaintsService(
        client: client,
        validateSession: () async => client.auth.currentSession);
    handle = storage;
    expect(await submit(), rows.keys.single);
    expect(requests.map((r) => r.method), ['POST', 'GET']);
    expect(rows, hasLength(1));
  });

  test('timeout and overlapping late commit retry share the primary key',
      () async {
    service = ComplaintsService(
        client: client,
        validateSession: () async => client.auth.currentSession,
        requestTimeout: const Duration(milliseconds: 40));
    final firstRequest = Completer<http.Request>();
    final lateResponse = Completer<http.Response>();
    handle = (request) async {
      firstRequest.complete(request);
      return lateResponse.future;
    };
    await expectLater(submit(), throwsA(isA<ComplaintSubmissionException>()));
    final timedOutRequest = await firstRequest.future;
    var reconciling = true;
    handle = (request) async {
      if (request.method == 'GET' && reconciling) {
        reconciling = false;
        // Read returns empty, then the first write commits before retry POST.
        lateResponse.complete(await storage(timedOutRequest));
        return _response(request, []);
      }
      return storage(request);
    };
    final id = await submit();
    expect(rows.keys.single, id);
    expect(requests.map((r) => r.method), ['POST', 'GET', 'POST', 'GET']);
    final posts = requests.where((r) => r.method == 'POST').toList();
    expect(jsonDecode(posts[0].body)['id'], jsonDecode(posts[1].body)['id']);
    expect(rows, hasLength(1));
  });

  test('unconfirmed or wrong-tenant returned row is never success', () async {
    handle = (request) async {
      final payload = jsonDecode(request.body) as Map<String, dynamic>;
      return _response(
          request, {...payload, 'restaurant_id': _otherRestaurant}, 201);
    };
    await expectLater(submit(), throwsA(isA<ComplaintSubmissionException>()));
    expect(requests, hasLength(1));
  });

  for (final dark in [false, true]) {
    testWidgets(
        'composer confirms once after server reply; Arabic RTL theme dark=$dark',
        (tester) async {
      tester.view.physicalSize = const Size(900, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final gate = Completer<void>();
      handle = (request) async {
        await gate.future;
        return storage(request);
      };
      bool? result;
      await tester.pumpWidget(MaterialApp(
        theme: dark ? AppTheme.dark() : AppTheme.light(),
        locale: const Locale('ar'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate
        ],
        home: Scaffold(
            body: Builder(
                builder: (context) => TextButton(
                    onPressed: () async {
                      result = await showComplaintComposerSheet(context,
                          restaurantId: _restaurant,
                          restaurantName: 'مطعم محلي',
                          complaintsService: service);
                    },
                    child: const Text('فتح الشكوى')))),
      ));
      await tester.tap(find.text('فتح الشكوى'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('إرسال'));
      await tester.pumpAndSettle();
      expect(requests, isEmpty);
      final fields = find.byType(TextFormField);
      expect(
          Directionality.of(tester.element(fields.first)), TextDirection.rtl);
      await tester.enterText(fields.first, _title);
      await tester.enterText(fields.last, _description);
      await tester.tap(find.text('إرسال'));
      await tester.tap(find.text('إرسال'));
      await tester.pump();
      expect(result, isNull);
      expect(
          tester.widget<ElevatedButton>(find.byType(ElevatedButton)).onPressed,
          isNull);
      expect(tester.widget<TextFormField>(fields.first).enabled, isFalse);
      gate.complete();
      await tester.pumpAndSettle();
      expect(result, isTrue);
      expect(rows, hasLength(1));
      expect(requests, hasLength(1));
      expect(tester.takeException(), isNull);
    });
  }
}
