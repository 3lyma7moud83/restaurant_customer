import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

class AppEnv {
  AppEnv._();

  static const Set<String> _allowedEnvironments = <String>{
    'dev',
    'staging',
    'prod',
  };
  static const String _defaultEnvironment = 'dev';
  static const String _primaryEnvFile = 'assets/env/app.env';
  static const List<String> _firebaseKeys = <String>[
    'FIREBASE_API_KEY',
    'FIREBASE_PROJECT_ID',
    'FIREBASE_MESSAGING_SENDER_ID',
    'FIREBASE_STORAGE_BUCKET',
    'FIREBASE_ANDROID_APP_ID',
    'FIREBASE_IOS_APP_ID',
    'FIREBASE_IOS_BUNDLE_ID',
    'FIREBASE_WEB_APP_ID',
    'FIREBASE_AUTH_DOMAIN',
    'FIREBASE_MEASUREMENT_ID',
    'FIREBASE_WEB_VAPID_KEY',
  ];

  static bool _loaded = false;
  static String _activeEnvironment = _defaultEnvironment;
  static String _loadedFile = _primaryEnvFile;

  static String get environment => _activeEnvironment;
  static String get loadedFile => _loadedFile;

  static String get mapboxToken => _readRequired('MAPBOX_TOKEN');

  static String get supabaseUrl => _readRequired('SUPABASE_URL');

  static String get supabaseAnonKey => _readRequired('SUPABASE_ANON_KEY');

  static String? get googleServerClientId =>
      _readOptional('GOOGLE_SERVER_CLIENT_ID');

  static String? get googleIosClientId => _readOptional('GOOGLE_IOS_CLIENT_ID');

  static String? get googleWebClientId => _readOptional('GOOGLE_WEB_CLIENT_ID');

  static Future<void> load() async {
    if (_loaded) {
      _validateRequiredValues();
      return;
    }

    try {
      await dotenv.load(fileName: _primaryEnvFile);
      _loadedFile = _primaryEnvFile;
      _activeEnvironment = _resolveActiveEnvironment(
        envValueFromFile: dotenv.env['APP_ENV'],
        loadedFile: _primaryEnvFile,
      );
      _validateRequiredValues();
      _loaded = true;
      debugPrint('ENV LOADED SUCCESSFULLY');
    } catch (error, stack) {
      debugPrint(
        '[env] Unable to load environment file "$_primaryEnvFile": $error',
      );
      Error.throwWithStackTrace(
        StateError(
          'Unable to load environment config from $_primaryEnvFile.',
        ),
        stack,
      );
    }
  }

  static String _resolveActiveEnvironment({
    required String? envValueFromFile,
    required String loadedFile,
  }) {
    final normalizedFromFile = _normalizeEnvironment(envValueFromFile);

    if (envValueFromFile != null &&
        envValueFromFile.trim().isNotEmpty &&
        normalizedFromFile == null) {
      throw StateError(
        'Invalid APP_ENV="$envValueFromFile" in $loadedFile. '
        'Allowed values: dev, staging, prod.',
      );
    }

    if (normalizedFromFile != null) {
      return normalizedFromFile;
    }
    return _defaultEnvironment;
  }

  static String? _normalizeEnvironment(String? raw) {
    if (raw == null) {
      return null;
    }
    final normalized = raw.trim().toLowerCase();
    if (normalized.isEmpty) {
      return null;
    }
    if (_allowedEnvironments.contains(normalized)) {
      return normalized;
    }
    return null;
  }

  static void _validateRequiredValues() {
    final url = _readRequired('SUPABASE_URL');
    final anonKey = _readRequired('SUPABASE_ANON_KEY');
    final mapboxToken = _readRequired('MAPBOX_TOKEN');

    final parsedUrl = Uri.tryParse(url);
    final validUrl = parsedUrl != null &&
        (parsedUrl.scheme == 'https' || parsedUrl.scheme == 'http') &&
        parsedUrl.host.isNotEmpty;
    if (!validUrl || _looksLikePlaceholder(url)) {
      throw StateError(
        'Invalid SUPABASE_URL in $_loadedFile for environment '
        '"$_activeEnvironment".',
      );
    }

    final anonParts = anonKey.split('.');
    if (anonParts.length != 3 || _looksLikePlaceholder(anonKey)) {
      throw StateError(
        'Invalid SUPABASE_ANON_KEY in $_loadedFile for environment '
        '"$_activeEnvironment".',
      );
    }

    final validMapboxToken =
        (mapboxToken.startsWith('pk.') || mapboxToken.startsWith('sk.')) &&
            !_looksLikePlaceholder(mapboxToken);
    if (!validMapboxToken) {
      throw StateError(
        'Invalid MAPBOX_TOKEN in $_loadedFile for environment '
        '"$_activeEnvironment".',
      );
    }

    _validateFirebaseValues();
  }

  static void _validateFirebaseValues() {
    final hasFirebaseConfig =
        _firebaseKeys.any((key) => _readOptional(key) != null);
    if (!hasFirebaseConfig) {
      return;
    }

    final androidAppId = _readOptional('FIREBASE_ANDROID_APP_ID');
    if (androidAppId != null && !androidAppId.contains(':android:')) {
      throw StateError(
        'Invalid FIREBASE_ANDROID_APP_ID in $_loadedFile. '
        'Expected an Android App ID containing ":android:".',
      );
    }

    final webAppId = _readOptional('FIREBASE_WEB_APP_ID');
    if (webAppId != null && !webAppId.contains(':web:')) {
      throw StateError(
        'Invalid FIREBASE_WEB_APP_ID in $_loadedFile. '
        'Expected a Web App ID containing ":web:".',
      );
    }

    final webVapidKey = _readOptional('FIREBASE_WEB_VAPID_KEY');
    if (webAppId != null &&
        (webVapidKey == null ||
            webVapidKey.length < 20 ||
            _looksLikePlaceholder(webVapidKey))) {
      throw StateError(
        'Missing or invalid FIREBASE_WEB_VAPID_KEY in $_loadedFile '
        'while FIREBASE_WEB_APP_ID is configured.',
      );
    }
  }

  static bool _looksLikePlaceholder(String value) {
    final lowered = value.trim().toLowerCase();
    if (lowered.isEmpty) {
      return true;
    }

    return lowered.contains('your_') ||
        lowered.contains('your-') ||
        lowered.contains('replace_with') ||
        lowered.contains('replace-with') ||
        lowered.contains('changeme') ||
        lowered.contains('placeholder') ||
        lowered.contains('<') ||
        lowered.contains('>');
  }

  static String _readRequired(String key) {
    final rawValue = dotenv.env[key];
    final value = rawValue == null ? null : _sanitize(rawValue);
    if (value == null || value.isEmpty) {
      throw StateError('Missing required environment variable "$key".');
    }
    return value;
  }

  static String? _readOptional(String key) {
    final rawValue = dotenv.env[key];
    final value = rawValue == null ? null : _sanitize(rawValue);
    if (value == null || value.isEmpty) {
      return null;
    }
    return value;
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
