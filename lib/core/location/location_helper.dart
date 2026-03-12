import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import '../services/error_logger.dart';
import 'location_result.dart';
import 'location_service.dart';

class LocationHelper {
  static Future<LocationResult?> requestAndGetLocation({
    String? mapboxToken,
  }) async {
    // ================= WEB =================
    if (kIsWeb) {
      try {
        final pos = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high,
        );

        return LocationResult(
          lat: pos.latitude,
          lng: pos.longitude,
          address: null,
        );
      } catch (error, stack) {
        await ErrorLogger.logError(
          module: 'location_helper.requestAndGetLocation.web',
          error: error,
          stack: stack,
        );
        return null;
      }
    }

    try {
      // ================= MOBILE =================
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();

      if (!serviceEnabled) {
        await Geolocator.openLocationSettings();
        return null;
      }

      LocationPermission permission = await Geolocator.checkPermission();

      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.deniedForever) {
        await Geolocator.openAppSettings();
        return null;
      }

      if (permission == LocationPermission.denied) {
        return null;
      }

      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      String? address;

      if (mapboxToken != null) {
        address = await LocationService.getAddress(
          lat: pos.latitude,
          lng: pos.longitude,
          token: mapboxToken,
        );
      }

      return LocationResult(
        lat: pos.latitude,
        lng: pos.longitude,
        address: address,
      );
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'location_helper.requestAndGetLocation',
        error: error,
        stack: stack,
      );
      return null;
    }
  }
}
