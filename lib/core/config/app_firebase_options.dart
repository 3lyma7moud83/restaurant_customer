import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

class AppFirebaseOptions {
  AppFirebaseOptions._();

  static String? get configurationError {
    if (kIsWeb) {
      return _webConfigurationError;
    }

    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return _androidConfigurationError;
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
        return _iosConfigurationError;
      default:
        return null;
    }
  }

  static FirebaseOptions? get currentPlatform {
    if (kIsWeb) {
      return _web;
    }

    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return _android;
      case TargetPlatform.iOS:
        return _ios;
      case TargetPlatform.macOS:
        return _ios;
      default:
        return null;
    }
  }

  static String? get webPushVapidKey => _read('FIREBASE_WEB_VAPID_KEY');

  static String? get _androidConfigurationError {
    final missing = _missingRequired([
      'FIREBASE_API_KEY',
      'FIREBASE_ANDROID_APP_ID',
      'FIREBASE_MESSAGING_SENDER_ID',
      'FIREBASE_PROJECT_ID',
    ]);
    if (missing.isNotEmpty) {
      return 'Missing required Android Firebase keys: ${missing.join(', ')}';
    }

    final appId = _read('FIREBASE_ANDROID_APP_ID');
    if (appId != null && !appId.contains(':android:')) {
      return 'FIREBASE_ANDROID_APP_ID must contain ":android:".';
    }
    return null;
  }

  static String? get _iosConfigurationError {
    final missing = _missingRequired([
      'FIREBASE_API_KEY',
      'FIREBASE_IOS_APP_ID',
      'FIREBASE_MESSAGING_SENDER_ID',
      'FIREBASE_PROJECT_ID',
      'FIREBASE_IOS_BUNDLE_ID',
    ]);
    if (missing.isNotEmpty) {
      return 'Missing required iOS Firebase keys: ${missing.join(', ')}';
    }
    return null;
  }

  static String? get _webConfigurationError {
    final missing = _missingRequired([
      'FIREBASE_API_KEY',
      'FIREBASE_WEB_APP_ID',
      'FIREBASE_MESSAGING_SENDER_ID',
      'FIREBASE_PROJECT_ID',
    ]);
    if (missing.isNotEmpty) {
      return 'Missing required Web Firebase keys: ${missing.join(', ')}';
    }

    final webAppId = _read('FIREBASE_WEB_APP_ID');
    if (webAppId != null && !webAppId.contains(':web:')) {
      return 'FIREBASE_WEB_APP_ID must contain ":web:".';
    }

    final vapidKey = webPushVapidKey;
    if (vapidKey == null || vapidKey.isEmpty) {
      return 'Missing FIREBASE_WEB_VAPID_KEY.';
    }
    return null;
  }

  static FirebaseOptions? get _android {
    final apiKey = _read('FIREBASE_API_KEY');
    final appId = _read('FIREBASE_ANDROID_APP_ID');
    final messagingSenderId = _read('FIREBASE_MESSAGING_SENDER_ID');
    final projectId = _read('FIREBASE_PROJECT_ID');
    if ([apiKey, appId, messagingSenderId, projectId]
        .any((value) => value == null)) {
      return null;
    }

    return FirebaseOptions(
      apiKey: apiKey!,
      appId: appId!,
      messagingSenderId: messagingSenderId!,
      projectId: projectId!,
      storageBucket: _read('FIREBASE_STORAGE_BUCKET'),
    );
  }

  static FirebaseOptions? get _ios {
    final apiKey = _read('FIREBASE_API_KEY');
    final appId = _read('FIREBASE_IOS_APP_ID');
    final messagingSenderId = _read('FIREBASE_MESSAGING_SENDER_ID');
    final projectId = _read('FIREBASE_PROJECT_ID');
    final iosBundleId = _read('FIREBASE_IOS_BUNDLE_ID');
    if ([apiKey, appId, messagingSenderId, projectId, iosBundleId]
        .any((value) => value == null)) {
      return null;
    }

    return FirebaseOptions(
      apiKey: apiKey!,
      appId: appId!,
      messagingSenderId: messagingSenderId!,
      projectId: projectId!,
      iosBundleId: iosBundleId!,
      storageBucket: _read('FIREBASE_STORAGE_BUCKET'),
    );
  }

  static FirebaseOptions? get _web {
    final apiKey = _read('FIREBASE_API_KEY');
    final appId = _read('FIREBASE_WEB_APP_ID');
    final messagingSenderId = _read('FIREBASE_MESSAGING_SENDER_ID');
    final projectId = _read('FIREBASE_PROJECT_ID');
    if ([apiKey, appId, messagingSenderId, projectId]
        .any((value) => value == null)) {
      return null;
    }

    return FirebaseOptions(
      apiKey: apiKey!,
      appId: appId!,
      messagingSenderId: messagingSenderId!,
      projectId: projectId!,
      authDomain: _read('FIREBASE_AUTH_DOMAIN'),
      storageBucket: _read('FIREBASE_STORAGE_BUCKET'),
      measurementId: _read('FIREBASE_MEASUREMENT_ID'),
    );
  }

  static String? _read(String key) {
    final rawValue = dotenv.env[key];
    if (rawValue == null) {
      return null;
    }

    final value = _sanitize(rawValue);
    if (value.isEmpty) {
      return null;
    }
    return value;
  }

  static List<String> _missingRequired(List<String> keys) {
    return keys.where((key) => _read(key) == null).toList(growable: false);
  }

  static String _sanitize(String rawValue) {
    final trimmed = rawValue.trim();
    if (trimmed.length >= 2) {
      final startsWithDouble = trimmed.startsWith('"') && trimmed.endsWith('"');
      final startsWithSingle = trimmed.startsWith("'") && trimmed.endsWith("'");
      if (startsWithDouble || startsWithSingle) {
        return trimmed.substring(1, trimmed.length - 1).trim();
      }
    }
    return trimmed;
  }
}
