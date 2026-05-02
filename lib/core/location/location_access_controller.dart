import 'package:geolocator/geolocator.dart';

import '../services/error_logger.dart';
import 'location_helper.dart';
import 'location_result.dart';

enum LocationAccessStatus {
  checking,
  granted,
  denied,
  deniedForever,
  serviceDisabled,
  unavailable,
}

class LocationAccessSnapshot {
  const LocationAccessSnapshot({
    required this.status,
    this.location,
  });

  const LocationAccessSnapshot.granted(this.location)
      : status = LocationAccessStatus.granted,
        assert(location != null);

  final LocationAccessStatus status;
  final LocationResult? location;

  bool get isGranted =>
      status == LocationAccessStatus.granted && location != null;
}

class LocationAccessController {
  static Future<LocationAccessSnapshot> resolve({
    bool requestIfNeeded = true,
    bool forceRefresh = false,
    String? mapboxToken,
  }) async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        return const LocationAccessSnapshot(
          status: LocationAccessStatus.serviceDisabled,
        );
      }

      var permission = await Geolocator.checkPermission();
      if ((permission == LocationPermission.denied ||
              permission == LocationPermission.unableToDetermine) &&
          requestIfNeeded) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.deniedForever) {
        return const LocationAccessSnapshot(
          status: LocationAccessStatus.deniedForever,
        );
      }

      if (permission == LocationPermission.denied ||
          permission == LocationPermission.unableToDetermine) {
        return const LocationAccessSnapshot(
          status: LocationAccessStatus.denied,
        );
      }

      final location = await LocationHelper.getLocationWithGrantedPermission(
        mapboxToken: mapboxToken,
        forceRefresh: forceRefresh,
      );
      if (location == null) {
        return const LocationAccessSnapshot(
          status: LocationAccessStatus.unavailable,
        );
      }

      return LocationAccessSnapshot.granted(location);
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'location_access_controller.resolve',
        error: error,
        stack: stack,
      );
      return const LocationAccessSnapshot(
        status: LocationAccessStatus.unavailable,
      );
    }
  }

  static Future<bool> openAppSettings() async {
    try {
      return await Geolocator.openAppSettings();
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'location_access_controller.open_app_settings',
        error: error,
        stack: stack,
      );
      return false;
    }
  }

  static Future<bool> openLocationSettings() async {
    try {
      return await Geolocator.openLocationSettings();
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'location_access_controller.open_location_settings',
        error: error,
        stack: stack,
      );
      return false;
    }
  }
}
