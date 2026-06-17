import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:restaurant_customer/core/localization/app_localizations.dart';
import 'package:restaurant_customer/pages/home_page.dart';
import 'package:restaurant_customer/pages/restaurant_menu_page.dart';

Widget _buildMenuHost({
  required TextDirection direction,
  required double width,
}) {
  return MaterialApp(
    home: Directionality(
      textDirection: direction,
      child: MediaQuery(
        data: MediaQueryData(size: Size(width, 820)),
        child: Scaffold(
          appBar: AppBar(
            automaticallyImplyLeading: false,
            leadingWidth: 74,
            leading: Padding(
              padding: const EdgeInsetsDirectional.only(start: 8),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: HomeDrawerMenuButton(viewportWidth: width),
              ),
            ),
            title: const Text('Home'),
            actions: [
              IconButton(
                onPressed: () {},
                icon: const Icon(Icons.language_rounded),
              ),
              IconButton(
                onPressed: () {},
                icon: const Icon(Icons.shopping_bag_outlined),
              ),
            ],
          ),
          drawer: const Drawer(
            child: Center(
              child: Text('drawer-visible-marker'),
            ),
          ),
        ),
      ),
    ),
  );
}

Widget _buildItemCardHost(Widget child) {
  return MaterialApp(
    locale: const Locale('ar'),
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: Center(child: child),
    ),
  );
}

void main() {
  testWidgets('Drawer menu button is visible, on start side, and opens drawer',
      (tester) async {
    await tester.pumpWidget(
      _buildMenuHost(
        direction: TextDirection.ltr,
        width: 390,
      ),
    );

    final menuButton = find.byKey(const Key('home-drawer-menu-button'));
    expect(menuButton, findsOneWidget);
    expect(find.text('drawer-visible-marker'), findsNothing);

    final scaffoldWidth = tester.getSize(find.byType(Scaffold)).width;
    final ltrCenter = tester.getCenter(menuButton);
    expect(ltrCenter.dx < scaffoldWidth / 2, isTrue);

    await tester.tap(menuButton);
    await tester.pumpAndSettle();

    expect(find.text('drawer-visible-marker'), findsOneWidget);
  });

  testWidgets('Drawer menu button moves to right side in RTL', (tester) async {
    await tester.pumpWidget(
      _buildMenuHost(
        direction: TextDirection.rtl,
        width: 390,
      ),
    );

    final menuButton = find.byKey(const Key('home-drawer-menu-button'));
    expect(menuButton, findsOneWidget);

    final scaffoldWidth = tester.getSize(find.byType(Scaffold)).width;
    final rtlCenter = tester.getCenter(menuButton);
    expect(rtlCenter.dx > scaffoldWidth / 2, isTrue);
  });

  testWidgets('ItemCard add button stays large and tappable', (tester) async {
    var addTapCount = 0;

    await tester.pumpWidget(
      _buildItemCardHost(
        SizedBox(
          width: 176,
          height: 212,
          child: ItemCard(
            itemId: 'burger',
            name: 'Burger',
            basePrice: 99,
            imageUrl: '',
            onAdd: (_) => addTapCount += 1,
          ),
        ),
      ),
    );

    final addButton = find.byKey(const Key('menu-item-add-button'));
    expect(addButton, findsOneWidget);

    final addSize = tester.getSize(addButton);
    expect(addSize.width >= 44, isTrue);
    expect(addSize.height >= 44, isTrue);

    final priceCenter = tester.getCenter(find.text('99 ج'));
    final addCenter = tester.getCenter(addButton);
    expect((priceCenter.dy - addCenter.dy).abs() < 30, isTrue);

    await tester.tap(addButton);
    await tester.pumpAndSettle();

    expect(addTapCount, 1);
  });

  testWidgets('ItemCard opens inline variant menu and updates selected variant',
      (tester) async {
    MenuItemVariant? addedVariant;

    await tester.pumpWidget(
      _buildItemCardHost(
        SizedBox(
          width: 176,
          height: 212,
          child: ItemCard(
            itemId: 'burger',
            name: 'Burger',
            basePrice: 10,
            imageUrl: '',
            variants: const [
              MenuItemVariant(id: 'regular', name: 'Regular', price: 10),
              MenuItemVariant(id: 'large', name: 'Large', price: 12),
            ],
            onAdd: (variant) => addedVariant = variant,
          ),
        ),
      ),
    );

    expect(find.text('Regular'), findsOneWidget);
    expect(find.text('10 ج'), findsOneWidget);

    await tester.tap(find.text('Regular'));
    await tester.pumpAndSettle();

    expect(find.text('Large'), findsOneWidget);

    await tester.tap(find.text('Large'));
    await tester.pumpAndSettle();

    expect(find.text('Large'), findsOneWidget);
    expect(find.text('12 ج'), findsOneWidget);

    await tester.tap(find.byKey(const Key('menu-item-add-button')));
    await tester.pumpAndSettle();

    expect(addedVariant?.id, 'large');
  });

  testWidgets('ItemCard hides variant overlay for a single variant',
      (tester) async {
    await tester.pumpWidget(
      _buildItemCardHost(
        SizedBox(
          width: 176,
          height: 212,
          child: ItemCard(
            itemId: 'burger',
            name: 'Burger',
            basePrice: 10,
            imageUrl: '',
            variants: const [
              MenuItemVariant(id: 'regular', name: 'Regular', price: 10),
            ],
            onAdd: (_) {},
          ),
        ),
      ),
    );

    expect(find.text('Regular'), findsNothing);
    expect(find.text('10 ج'), findsOneWidget);
  });
}
