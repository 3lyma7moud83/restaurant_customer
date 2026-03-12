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

      final res = await http.get(Uri.parse(url));
      final data = jsonDecode(res.body);
      final distance = data["routes"][0]["distance"];

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
