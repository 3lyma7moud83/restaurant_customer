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
    final value = dotenv.env[key]?.trim();
    if (value == null || value.isEmpty) {
      throw StateError('Missing required environment variable "$key".');
    }
    return value;
  }

  static String? _readOptional(String key) {
    final value = dotenv.env[key]?.trim();
    if (value == null || value.isEmpty) {
      return null;
    }
    return value;
  }
}
