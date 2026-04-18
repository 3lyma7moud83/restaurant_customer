import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_localizations.dart';

class LocaleController extends ChangeNotifier {
  LocaleController();

  static const String _storageKey = 'customer_app_locale_code';

  Locale _locale = const Locale('ar');

  Locale get locale => _locale;
  bool get isArabic => _locale.languageCode.toLowerCase() == 'ar';

  Future<void> initialize() async {
    final preferences = await SharedPreferences.getInstance();
    final storedCode = preferences.getString(_storageKey)?.trim();
    if (storedCode == null || storedCode.isEmpty) {
      return;
    }

    final candidate = Locale(storedCode.toLowerCase());
    if (!_isSupported(candidate) || candidate == _locale) {
      return;
    }

    _locale = candidate;
    notifyListeners();
  }

  Future<void> toggleLocale() {
    return setLocale(isArabic ? const Locale('en') : const Locale('ar'));
  }

  Future<void> setLocale(Locale locale) async {
    if (!_isSupported(locale) || _locale == locale) {
      return;
    }

    _locale = locale;
    notifyListeners();

    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_storageKey, locale.languageCode.toLowerCase());
  }

  bool _isSupported(Locale locale) {
    return AppLocalizations.supportedLocales.any(
      (supportedLocale) => supportedLocale.languageCode == locale.languageCode,
    );
  }
}

class AppLocaleScope extends InheritedNotifier<LocaleController> {
  const AppLocaleScope({
    super.key,
    required LocaleController controller,
    required super.child,
  }) : super(notifier: controller);

  static LocaleController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppLocaleScope>();
    final controller = scope?.notifier;
    assert(controller != null, 'AppLocaleScope not found in widget tree.');
    return controller!;
  }

  static LocaleController read(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<AppLocaleScope>();
    final controller = scope?.notifier;
    assert(controller != null, 'AppLocaleScope not found in widget tree.');
    return controller!;
  }
}
