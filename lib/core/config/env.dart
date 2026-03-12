import 'package:flutter_dotenv/flutter_dotenv.dart';

class AppEnv {
  static String get mapboxToken => _readRequired('MAPBOX_TOKEN');

  static String get supabaseUrl => _readRequired('SUPABASE_URL');

  static String get supabaseAnonKey => _readRequired('SUPABASE_ANON_KEY');

  static String _readRequired(String key) {
    final value = dotenv.env[key]?.trim();
    if (value == null || value.isEmpty) {
      throw StateError('Missing required environment variable: $key');
    }
    return value;
  }
}
