import 'package:firebase_core/firebase_core.dart';

import 'core/config/app_firebase_options.dart';

class DefaultFirebaseOptions {
  DefaultFirebaseOptions._();

  static FirebaseOptions? get currentPlatform =>
      AppFirebaseOptions.currentPlatform;
}
