import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ThemeController extends ChangeNotifier {
  static const _storageKey = 'customer_theme_mode';

  ThemeController({ThemeMode initialMode = ThemeMode.light})
      : _themeMode = initialMode;

  ThemeMode _themeMode;
  ThemeMode get themeMode => _themeMode;

  static Future<ThemeMode> loadInitialMode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_storageKey) == true
        ? ThemeMode.dark
        : ThemeMode.light;
  }

  Future<void> initialize() async {
    _themeMode = await loadInitialMode();
    notifyListeners();
  }

  Future<void> toggle() async {
    _themeMode =
        _themeMode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_storageKey, _themeMode == ThemeMode.dark);
  }
}

class AppThemeScope extends InheritedNotifier<ThemeController> {
  const AppThemeScope({
    super.key,
    required ThemeController controller,
    required super.child,
  }) : super(notifier: controller);

  static ThemeController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppThemeScope>();
    assert(scope?.notifier != null, 'AppThemeScope not found in widget tree.');
    return scope!.notifier!;
  }
}
