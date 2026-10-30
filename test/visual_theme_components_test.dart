import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:restaurant_customer/core/localization/app_localizations.dart';
import 'package:restaurant_customer/core/orders/delivery_confirmation_ui.dart';
import 'package:restaurant_customer/core/orders/order_status_utils.dart';
import 'package:restaurant_customer/core/orders/order_ui.dart';
import 'package:restaurant_customer/core/theme/app_theme.dart';
import 'package:restaurant_customer/core/theme/theme_controller.dart';
import 'package:restaurant_customer/core/ui/app_components.dart';
import 'package:restaurant_customer/core/ui/app_motion.dart';
import 'package:restaurant_customer/main.dart' hide main;
import 'package:restaurant_customer/pages/home_page.dart';
import 'package:restaurant_customer/pages/restaurant_menu_page.dart';
import 'package:restaurant_customer/services/restaurants_service.dart';
import 'package:restaurant_customer/widgets/restaurant_card_components.dart';
import 'package:restaurant_customer/widgets/restaurant_info_sheet.dart';

const _captureKey = ValueKey('visual-capture-root');
const _restaurant = <String, dynamic>{
  'id': 'local-restaurant',
  'restaurant_id': 'local-restaurant',
  'restaurant_name': 'مطعم الاختبار المحلي',
  'name': 'مطعم الاختبار المحلي',
  'opening_time': '09:00',
  'closing_time': '23:00',
  'address': 'عنوان محلي للعرض',
  'image_url': '',
};

Widget _host(ValueNotifier<ThemeMode> mode, Widget home) => RepaintBoundary(
      key: _captureKey,
      child: ValueListenableBuilder<ThemeMode>(
        valueListenable: mode,
        builder: (_, value, child) => MaterialApp(
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: value,
          debugShowCheckedModeBanner: false,
          locale: const Locale('ar'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate
          ],
          home: child,
        ),
        child: home,
      ),
    );

double _contrast(Color foreground, Color background) {
  final a = foreground.computeLuminance(), b = background.computeLuminance();
  return a > b ? (a + .05) / (b + .05) : (b + .05) / (a + .05);
}

Future<void> _capture(WidgetTester tester, String name) async {
  final path = Platform.environment['VISUAL_CAPTURE_DIR'];
  if (path == null) return;
  await tester.runAsync(() async {
    final boundary =
        tester.renderObject<RenderRepaintBoundary>(find.byKey(_captureKey));
    final raster = await boundary.toImage(pixelRatio: 1);
    final bytes = await raster.toByteData(format: ui.ImageByteFormat.png);
    await Directory(path).create(recursive: true);
    await File('$path/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
    raster.dispose();
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  var requests = 0;
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    final cairo = FontLoader('Cairo')
      ..addFont(rootBundle.load('assets/fonts/Cairo-Regular.ttf'));
    await cairo.load();
    for (final entry in {
      'Noto Sans': 'assets/fonts/NotoSans-Regular.ttf',
      'Noto Sans Arabic': 'assets/fonts/NotoSansArabic-Regular.ttf',
      'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
      'CupertinoIcons': 'packages/cupertino_icons/assets/CupertinoIcons.ttf',
    }.entries) {
      final loader = FontLoader(entry.key)
        ..addFont(rootBundle.load(entry.value));
      await loader.load();
    }
    await Supabase.initialize(
      url: 'https://visual-test.invalid',
      publishableKey: 'local-fixture-only',
      httpClient: MockClient((request) async {
        requests++;
        expect(request.url.host, 'visual-test.invalid');
        return http.Response(
            request.url.path.endsWith('/managers')
                ? jsonEncode([_restaurant])
                : '[]',
            200,
            request: request,
            headers: {'content-type': 'application/json'});
      }),
      authOptions: const FlutterAuthClientOptions(
          autoRefreshToken: false,
          detectSessionInUri: false,
          persistSession: false),
    );
  });
  tearDownAll(() async => Supabase.instance.dispose());

  for (final dark in [false, true]) {
    final name = dark ? 'dark' : 'light';
    test('semantic text/background pairs have readable contrast ($name)', () {
      final theme = dark ? AppTheme.dark() : AppTheme.light();
      final colors = theme.extension<AppThemeColors>()!;
      for (final pair in [
        [theme.colorScheme.onPrimary, theme.colorScheme.primary],
        [theme.colorScheme.onSurface, theme.colorScheme.surface],
        [colors.success, colors.successContainer],
        [colors.warning, colors.warningContainer],
        [colors.danger, colors.dangerContainer],
        [colors.info, colors.infoContainer]
      ]) {
        expect(_contrast(pair[0], pair[1]), greaterThanOrEqualTo(4.5));
      }
    });

    testWidgets(
        'production header, restaurant, item, states and Drawer ($name)',
        (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 1000);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final mode = ValueNotifier(dark ? ThemeMode.dark : ThemeMode.light);
      addTearDown(mode.dispose);
      await tester.pumpWidget(_host(
          mode,
          Scaffold(
            appBar: AppBar(title: const HomeAppBarTitle()),
            body: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      RestaurantListCard(
                          name: 'مطعم الاختبار المحلي',
                          imageUrl: '',
                          deliveryMinutes: 25,
                          categoryLabel: 'وجبات',
                          distanceLabel: '2 كم',
                          statusLabel: 'مفتوح الآن',
                          statusPositive: true,
                          onTap: () {},
                          onInfoTap: () {}),
                      const SizedBox(height: 16),
                      const Align(
                          child: SizedBox(
                              width: 180,
                              height: 202,
                              child: ItemCard(
                                  itemId: 'local-item',
                                  name: 'وجبة محلية',
                                  basePrice: 25,
                                  imageUrl: '',
                                  variants: [
                                    MenuItemVariant(
                                        id: 'small', name: 'صغير', price: 25),
                                    MenuItemVariant(
                                        id: 'large', name: 'كبير', price: 40)
                                  ],
                                  onAdd: _ignoreVariant))),
                      const SizedBox(height: 16),
                      DeliveryConfirmationBanner(onOpenConfirmation: () {}),
                      const SizedBox(height: 12),
                      Wrap(spacing: 8, runSpacing: 8, children: [
                        for (final status in [
                          'pending',
                          'accepted',
                          'completed',
                          'rejected'
                        ])
                          OrderStatusBadge(info: resolveOrderStatus(status)),
                      ]),
                      const SizedBox(height: 12),
                      AppButton(
                          label: 'زر ثانوي',
                          variant: AppButtonVariant.secondary,
                          onPressed: () {}),
                    ])),
          )));
      await tester.pumpAndSettle();
      expect(find.byType(RestaurantListCard), findsOneWidget);
      final scheme =
          Theme.of(tester.element(find.byType(ItemCard))).colorScheme;
      final label = tester.widget<Text>(find.text('زر ثانوي'));
      expect(label.style!.color, scheme.onSurface);
      expect(tester.takeException(), isNull);
      await _capture(tester, 'components_$name');
      await tester.pumpWidget(_host(
          mode,
          Scaffold(
            appBar: AppBar(title: const HomeAppBarTitle()),
            drawer: HomeMainDrawer(client: Supabase.instance.client),
          )));
      tester.state<ScaffoldState>(find.byType(Scaffold)).openDrawer();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await _capture(tester, 'drawer_$name');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets(
        'exclamation opens themed facts and updates existing sheet ($name)',
        (tester) async {
      final mode = ValueNotifier(dark ? ThemeMode.dark : ThemeMode.light);
      addTearDown(mode.dispose);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpWidget(_host(
          mode,
          Scaffold(
              body: Builder(
            builder: (context) => RestaurantListCard(
                name: 'مطعم الاختبار المحلي',
                imageUrl: '',
                deliveryMinutes: 25,
                categoryLabel: null,
                distanceLabel: null,
                statusLabel: 'مفتوح',
                statusPositive: true,
                onTap: () {},
                onInfoTap: () => unawaited(
                    showRestaurantInfoSheet(context, restaurant: _restaurant))),
          ))));
      await tester.tap(find.byIcon(Icons.error_outline_rounded));
      await tester.pumpAndSettle();
      await tester.runAsync(() =>
          RestaurantsService.getManagerDetailsByRestaurantId(
              'local-restaurant'));
      await tester.pumpAndSettle();
      final address = find.text('عنوان محلي للعرض');
      expect(address, findsOneWidget);
      void verifyFacts() {
        final scheme = Theme.of(tester.element(address)).colorScheme;
        expect(tester.widget<Text>(address).style!.color, scheme.onSurface);
        final backgrounds = tester.widgetList<DecoratedBox>(
            find.ancestor(of: address, matching: find.byType(DecoratedBox)));
        expect(
            backgrounds.any((box) =>
                box.decoration is BoxDecoration &&
                (box.decoration as BoxDecoration).color == scheme.surface),
            isTrue);
      }

      verifyFacts();
      await _capture(tester, 'restaurant_info_$name');
      final before = requests;
      mode.value = dark ? ThemeMode.light : ThemeMode.dark;
      await tester.pumpAndSettle();
      verifyFacts();
      expect(requests, before);
      expect(tester.takeException(), isNull);
      Navigator.of(tester.element(address)).pop();
      await tester.pumpAndSettle();
    });

    testWidgets('complaint fields and cancel retain theme and input ($name)',
        (tester) async {
      final mode = ValueNotifier(dark ? ThemeMode.dark : ThemeMode.light);
      addTearDown(mode.dispose);
      Future<bool?>? result;
      await tester.pumpWidget(_host(
          mode,
          Scaffold(
              body: Builder(
                  builder: (context) => TextButton(
                      onPressed: () {
                        result = showComplaintComposerSheet(context,
                            restaurantId: 'local-restaurant',
                            restaurantName: 'مطعم الاختبار المحلي');
                      },
                      child: const Text('Open complaint'))))));
      await tester.tap(find.text('Open complaint'));
      await tester.pumpAndSettle();
      final title = find.byType(TextFormField).first;
      await tester.enterText(title, 'عنوان محلي محفوظ');
      await tester.pumpAndSettle();
      final controller = tester.widget<TextFormField>(title).controller;
      final before = requests;
      await _capture(tester, 'complaint_$name');
      mode.value = dark ? ThemeMode.light : ThemeMode.dark;
      await tester.pumpAndSettle();
      expect(tester.widget<TextFormField>(title).controller, same(controller));
      expect(controller!.text, 'عنوان محلي محفوظ');
      expect(
          Theme.of(tester.element(title)).inputDecorationTheme.fillColor,
          (dark ? AppTheme.light() : AppTheme.dark())
              .inputDecorationTheme
              .fillColor);
      expect(requests, before);
      Navigator.of(tester.element(title)).pop();
      await tester.pumpAndSettle();
      expect(await result, isNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'confirmation warnings and pending success follow theme ($name)',
        (tester) async {
      final mode = ValueNotifier(dark ? ThemeMode.dark : ThemeMode.light);
      addTearDown(mode.dispose);
      final completed = Completer<void>();
      var confirmations = 0;
      await tester.pumpWidget(_host(
          mode,
          Scaffold(
              body: Builder(
                  builder: (context) => TextButton(
                      onPressed: () => unawaited(showDeliveryConfirmationDialog(
                          context: context,
                          order: const {
                            'id': 'local-order',
                            'receipt_number': 'LOCAL-01'
                          },
                          onConfirm: () {
                            confirmations++;
                            return completed.future;
                          })),
                      child: const Text('Open'))))));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('لم أستلم الطلب'));
      await tester.pumpAndSettle();
      final warning = find.text(
          'سيبقى الطلب على حالته الحالية حتى تؤكد الاستلام. يمكنك التواصل مع السائق مباشرة الآن.');
      final colors = AppTheme.colorsOf(tester.element(warning));
      expect(tester.widget<Text>(warning).style!.color, colors.warning);
      await _capture(tester, 'confirmation_$name');
      await tester.tap(find.text('استلمت الطلب'));
      await tester.pump();
      await tester.tap(find.text('استلمت الطلب'));
      expect(confirmations, 1);
      completed.complete();
      await tester.pump();
      final success =
          find.text('تم إرسال التأكيد. بانتظار تحديث السيرفر الرسمي.');
      expect(tester.widget<Text>(success).style!.color, colors.success);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets(
      'actual CustomerApp theme persists through pages without data reload',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const CustomerApp(
        bootstrapResult: BootstrapResult.fail('app.bootstrap_env_error')));
    await tester.pumpAndSettle();
    final controller =
        AppThemeScope.of(tester.element(find.byType(MaterialApp)));
    final form = TextEditingController(text: 'preserved');
    final pageKey = GlobalKey();
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.push(AppTheme.platformPageRoute<void>(
        motion: AppRouteMotion.detail,
        builder: (_) =>
            Scaffold(key: pageKey, body: TextField(controller: form))));
    await tester.pumpAndSettle();
    final pageElement = pageKey.currentContext;
    final before = requests;
    await controller.toggle();
    await tester.pumpAndSettle();
    expect(Theme.of(pageKey.currentContext!).brightness, Brightness.dark);
    expect(pageKey.currentContext, same(pageElement));
    expect(form.text, 'preserved');
    expect(requests, before);
    expect(await ThemeController.loadInitialMode(), ThemeMode.dark);
    navigator.pop();
    await tester.pumpAndSettle();
    expect(Theme.of(tester.element(find.byType(Scaffold))).brightness,
        Brightness.dark);
    await tester.pumpWidget(const SizedBox());
    form.dispose();
  });

  test('route intents have distinct bounded durations', () {
    final routes = [
      for (final motion in AppRouteMotion.values)
        AppTheme.platformPageRoute<void>(
            motion: motion, builder: (_) => const SizedBox())
    ];
    expect(routes.map((route) => route.transitionDuration.inMilliseconds),
        [260, 300, 280]);
    expect(routes.every((route) => route.maintainState), isTrue);
  });
}

void _ignoreVariant(MenuItemVariant? variant) {}
