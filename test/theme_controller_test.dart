import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:restaurant_customer/core/theme/theme_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('theme toggle switches mode without affecting unrelated preferences',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'session_marker': 'preserved',
    });
    final controller = ThemeController();

    await controller.initialize();
    expect(controller.themeMode, ThemeMode.light);

    await controller.toggle();
    expect(controller.themeMode, ThemeMode.dark);

    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getBool('customer_theme_mode'), isTrue);
    expect(preferences.getString('session_marker'), 'preserved');
  });

  test('saved dark mode is restored on a new controller', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'customer_theme_mode': true,
    });

    final controller = ThemeController();
    await controller.initialize();

    expect(controller.themeMode, ThemeMode.dark);
  });
}
