import 'dart:async';

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
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        return null;
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.unableToDetermine) {
        permission = await Geolocator.requestPermission();
      }

      if (_isDeniedPermission(permission)) {
        return null;
      }

      return getLocationWithGrantedPermission(
        mapboxToken: mapboxToken,
        forceRefresh: forceRefresh,
      );
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

  static Future<LocationResult?> getLocationWithGrantedPermission({
    String? mapboxToken,
    bool forceRefresh = false,
  }) async {
    final now = DateTime.now();
    final cached = _getCachedLocationIfFresh(
      now: now,
      mapboxToken: mapboxToken,
      forceRefresh: forceRefresh,
    );
    if (cached != null) {
      return cached;
    }

    try {
      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 10),
      );
      final address = await _resolveAddress(
        lat: pos.latitude,
        lng: pos.longitude,
        mapboxToken: mapboxToken,
      );
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
        module: 'location_helper.getLocationWithGrantedPermission',
        error: error,
        stack: stack,
      );
      return null;
    }
  }

  static LocationResult? _getCachedLocationIfFresh({
    required DateTime now,
    required String? mapboxToken,
    required bool forceRefresh,
  }) {
    if (forceRefresh) {
      return null;
    }

    final cached = _cachedLocation;
    final cachedAt = _cachedAt;
    final isFresh = cached != null &&
        cachedAt != null &&
        now.difference(cachedAt) <= _cacheTtl;
    if (!isFresh) {
      return null;
    }

    if (mapboxToken == null || (cached.address ?? '').trim().isNotEmpty) {
      return cached;
    }

    return _enrichCachedAddress(
      cached: cached,
      now: now,
      mapboxToken: mapboxToken,
    );
  }

  static LocationResult _enrichCachedAddress({
    required LocationResult cached,
    required DateTime now,
    required String mapboxToken,
  }) {
    unawaited(() async {
      try {
        final address = await LocationService.getAddress(
          lat: cached.lat,
          lng: cached.lng,
          token: mapboxToken,
        );
        if (address == null || address.trim().isEmpty) {
          return;
        }

        final latestCached = _cachedLocation;
        if (latestCached == null ||
            latestCached.lat != cached.lat ||
            latestCached.lng != cached.lng) {
          return;
        }

        _cachedLocation = LocationResult(
          lat: cached.lat,
          lng: cached.lng,
          address: address,
        );
        _cachedAt = now;
      } catch (error, stack) {
        await ErrorLogger.logError(
          module: 'location_helper.cache.enrich_address',
          error: error,
          stack: stack,
        );
      }
    }());

    return cached;
  }

  static Future<String?> _resolveAddress({
    required double lat,
    required double lng,
    required String? mapboxToken,
  }) async {
    if (mapboxToken == null) {
      return null;
    }

    try {
      return await LocationService.getAddress(
        lat: lat,
        lng: lng,
        token: mapboxToken,
      );
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'location_helper.requestAndGetLocation.address',
        error: error,
        stack: stack,
      );
      return null;
    }
  }

  static bool _isDeniedPermission(LocationPermission permission) {
    return permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever ||
        permission == LocationPermission.unableToDetermine;
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
