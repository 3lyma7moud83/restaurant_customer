import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

class AppFirebaseOptions {
  AppFirebaseOptions._();

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
    final value = dotenv.env[key]?.trim();
    if (value == null || value.isEmpty) {
      return null;
    }
    return value;
  }
}
