import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/config/env.dart';
import '../core/services/error_logger.dart';

class LocationDistanceService {
  /// بيرجع المسافة بالمتر بين نقطتين.
  static Future<double> getDistance({
    required double fromLat,
    required double fromLng,
    required double toLat,
    required double toLng,
  }) async {
    try {
      final url = "https://api.mapbox.com/directions/v5/mapbox/driving/"
          "$fromLng,$fromLat;"
          "$toLng,$toLat"
          "?access_token=${AppEnv.mapboxToken}&overview=false";

      final res =
          await http.get(Uri.parse(url)).timeout(const Duration(seconds: 10));

      if (res.statusCode != 200) {
        throw Exception('Mapbox directions failed (${res.statusCode})');
      }

      final data = jsonDecode(res.body);
      final routes = data is Map ? data['routes'] : null;
      if (routes is! List || routes.isEmpty) {
        throw Exception('Mapbox directions returned no routes');
      }

      final first = routes.first;
      if (first is! Map) {
        throw Exception('Invalid Mapbox directions response');
      }

      final distance = first['distance'];
      if (distance is! num) {
        throw Exception('Invalid distance value');
      }

      return distance.toDouble();
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'location_distance_service.getDistance',
        error: error,
        stack: stack,
      );
      throw Exception(ErrorLogger.userMessage);
    }
  }
}
