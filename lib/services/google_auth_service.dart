import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/config/env.dart';
import '../core/services/error_logger.dart';
import 'profile_service.dart';

enum GoogleAuthStatus {
  success,
  cancelled,
  redirecting,
}

class GoogleAuthResult {
  const GoogleAuthResult({
    required this.status,
    this.message,
  });

  final GoogleAuthStatus status;
  final String? message;
}

class GoogleAuthService {
  GoogleAuthService({
    SupabaseClient? client,
    ProfileService? profileService,
  })  : _client = client ?? Supabase.instance.client,
        _profileService = profileService ?? ProfileService();

  final SupabaseClient _client;
  final ProfileService _profileService;

  Future<GoogleAuthResult> signIn() async {
    if (kIsWeb) {
      await _client.auth.signInWithOAuth(
        OAuthProvider.google,
      );
      return const GoogleAuthResult(
        status: GoogleAuthStatus.redirecting,
      );
    }

    final isSupportedPlatform =
        defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS;
    if (!isSupportedPlatform) {
      throw Exception('Google Sign-In غير مدعوم على هذا النظام.');
    }

    try {
      final googleSignIn = GoogleSignIn(
        scopes: const ['email', 'profile'],
        serverClientId: AppEnv.googleServerClientId,
        clientId: defaultTargetPlatform == TargetPlatform.iOS
            ? AppEnv.googleIosClientId
            : null,
      );

      final account = await googleSignIn.signIn();
      if (account == null) {
        return const GoogleAuthResult(
          status: GoogleAuthStatus.cancelled,
          message: 'تم إلغاء تسجيل الدخول عبر Google.',
        );
      }

      final authentication = await account.authentication;
      final idToken = authentication.idToken;
      final accessToken = authentication.accessToken;
      if (idToken == null || accessToken == null) {
        throw Exception(
          'تعذر الحصول على بيانات التحقق من Google. تأكد من إعداد GOOGLE_SERVER_CLIENT_ID.',
        );
      }

      await _client.auth.signInWithIdToken(
        provider: OAuthProvider.google,
        idToken: idToken,
        accessToken: accessToken,
      );

      await _profileService.syncProfileFromAuth(
        name: account.displayName,
        imageUrl: account.photoUrl,
      );

      return const GoogleAuthResult(status: GoogleAuthStatus.success);
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'google_auth_service.signIn',
        error: error,
        stack: stack,
      );
      rethrow;
    }
  }
}
