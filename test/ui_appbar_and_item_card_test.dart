import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 176,
              height: 212,
              child: ItemCard(
                name: 'Burger',
                priceText: '99',
                imageUrl: '',
                quantity: 0,
                onAdd: () => addTapCount += 1,
              ),
            ),
          ),
        ),
      ),
    );

    final addButton = find.byKey(const Key('menu-item-add-button'));
    expect(addButton, findsOneWidget);

    final addSize = tester.getSize(addButton);
    expect(addSize.width >= 44, isTrue);
    expect(addSize.height >= 44, isTrue);

    final priceCenter = tester.getCenter(find.text('99'));
    final addCenter = tester.getCenter(addButton);
    expect((priceCenter.dy - addCenter.dy).abs() < 30, isTrue);

    await tester.tap(addButton);
    await tester.pumpAndSettle();

    expect(addTapCount, 1);
  });
}
