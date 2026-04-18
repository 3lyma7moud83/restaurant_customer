import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/config/env.dart';
import '../core/services/error_logger.dart';
import 'profile_service.dart';

enum GoogleAuthStatus {
  success,
  cancelled,
  redirecting,
  failed,
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
      return const GoogleAuthResult(
        status: GoogleAuthStatus.failed,
        message: 'Google Sign-In غير مدعوم على هذا النظام.',
      );
    }

    final serverClientId = AppEnv.googleServerClientId?.trim();
    if (serverClientId == null || serverClientId.isEmpty) {
      return const GoogleAuthResult(
        status: GoogleAuthStatus.failed,
        message:
            'إعداد Google Sign-In غير مكتمل. أضف GOOGLE_SERVER_CLIENT_ID الصحيح.',
      );
    }

    try {
      final googleSignIn = GoogleSignIn(
        scopes: const ['email', 'profile'],
        serverClientId: serverClientId,
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
        return const GoogleAuthResult(
          status: GoogleAuthStatus.failed,
          message:
              'تعذر الحصول على بيانات Google. تحقق من إعداد OAuth و GOOGLE_SERVER_CLIENT_ID.',
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
      return GoogleAuthResult(
        status: GoogleAuthStatus.failed,
        message: _friendlyErrorMessage(error),
      );
    }
  }

  String _friendlyErrorMessage(Object error) {
    if (error is PlatformException) {
      final combined = [
        error.code,
        error.message,
        error.details?.toString(),
      ].join(' ').toLowerCase();

      if (combined.contains('apiexception: 10') ||
          combined.contains('sign_in_failed') ||
          combined.contains('developer_error')) {
        return 'فشل تسجيل Google بسبب إعدادات Firebase/OAuth. '
            'أضف SHA-1 وSHA-256 لشهادة Android داخل Firebase، '
            'ثم أعد تنزيل google-services.json وتأكد من GOOGLE_SERVER_CLIENT_ID.';
      }
    }

    final normalized = error.toString().toLowerCase();
    if (normalized.contains('apiexception: 10')) {
      return 'Google Sign-In غير مهيأ بشكل صحيح. '
          'تحقق من SHA-1 وGoogle OAuth Client ID.';
    }

    return 'تعذر تسجيل الدخول عبر Google حالياً. حاول مرة أخرى.';
  }
}
