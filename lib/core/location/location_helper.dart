import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import '../services/error_logger.dart';
import 'location_result.dart';
import 'location_service.dart';

class LocationHelper {
  static const Duration _cacheTtl = Duration(minutes: 2);
  static LocationResult? _cachedLocation;
  static DateTime? _cachedAt;

  static Future<LocationResult?> requestAndGetLocation({
    String? mapboxToken,
    bool forceRefresh = false,
  }) async {
    final now = DateTime.now();
    if (!forceRefresh) {
      final cached = _cachedLocation;
      final cachedAt = _cachedAt;
      final isFresh = cached != null &&
          cachedAt != null &&
          now.difference(cachedAt) <= _cacheTtl;
      if (isFresh) {
        if (mapboxToken == null) {
          return cached;
        }
        if ((cached.address ?? '').trim().isNotEmpty) {
          return cached;
        }
        String? address;
        try {
          address = await LocationService.getAddress(
            lat: cached.lat,
            lng: cached.lng,
            token: mapboxToken,
          );
        } catch (error, stack) {
          await ErrorLogger.logError(
            module: 'location_helper.cache.enrich_address',
            error: error,
            stack: stack,
          );
        }
        final enriched = LocationResult(
          lat: cached.lat,
          lng: cached.lng,
          address: address,
        );
        _cachedLocation = enriched;
        _cachedAt = now;
        return enriched;
      }
    }

    // ================= WEB =================
    if (kIsWeb) {
      try {
        final serviceEnabled = await Geolocator.isLocationServiceEnabled();
        if (!serviceEnabled) {
          return null;
        }

        var permission = await Geolocator.checkPermission();
        if (permission == LocationPermission.denied) {
          permission = await Geolocator.requestPermission();
        }
        if (permission == LocationPermission.denied ||
            permission == LocationPermission.deniedForever) {
          return null;
        }

        final pos = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high,
          timeLimit: const Duration(seconds: 10),
        );

        final location = LocationResult(
          lat: pos.latitude,
          lng: pos.longitude,
          address: null,
        );
        _cachedLocation = location;
        _cachedAt = now;
        return location;
      } catch (error, stack) {
        if (_isLocationUnavailableError(error)) {
          return null;
        }
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
        return null;
      }

      LocationPermission permission = await Geolocator.checkPermission();

      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.deniedForever) {
        return null;
      }

      if (permission == LocationPermission.denied) {
        return null;
      }

      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 10),
      );

      String? address;

      if (mapboxToken != null) {
        try {
          address = await LocationService.getAddress(
            lat: pos.latitude,
            lng: pos.longitude,
            token: mapboxToken,
          );
        } catch (error, stack) {
          await ErrorLogger.logError(
            module: 'location_helper.requestAndGetLocation.address',
            error: error,
            stack: stack,
          );
        }
      }

      final location = LocationResult(
        lat: pos.latitude,
        lng: pos.longitude,
        address: address,
      );
      _cachedLocation = location;
      _cachedAt = now;
      return location;
    } catch (error, stack) {
      if (_isLocationUnavailableError(error)) {
        return null;
      }
      await ErrorLogger.logError(
        module: 'location_helper.requestAndGetLocation',
        error: error,
        stack: stack,
      );
      return null;
    }
  }

  static bool _isLocationUnavailableError(Object error) {
    if (error is TimeoutException) {
      return true;
    }
    final message = error.toString().toLowerCase();
    return message.contains('permission') ||
        message.contains('denied') ||
        message.contains('location services are disabled') ||
        message.contains('location unavailable') ||
        message.contains('unsupported');
  }
}
