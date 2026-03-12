import 'dart:convert';

import 'package:http/http.dart' as http;

import '../services/error_logger.dart';

class LocationAddressDetails {
  const LocationAddressDetails({
    required this.address,
    this.houseNumber,
  });

  final String address;
  final String? houseNumber;
}

class LocationService {
  static Future<LocationAddressDetails?> getAddressDetails({
    required double lat,
    required double lng,
    required String token,
  }) async {
    try {
      final url =
          "https://api.mapbox.com/geocoding/v5/mapbox.places/$lng,$lat.json"
          "?language=ar"
          "&types=address,neighborhood,locality,place"
          "&access_token=$token";

      final res = await http.get(Uri.parse(url));
      if (res.statusCode != 200) {
        return null;
      }

      final data = jsonDecode(res.body);
      final List features = data['features'] ?? const [];
      if (features.isEmpty) {
        return null;
      }

      final place = features.firstWhere(
        (feature) {
          final types = (feature['place_type'] as List?) ?? const [];
          return types.contains('address') ||
              types.contains('neighborhood') ||
              types.contains('locality');
        },
        orElse: () => features[0],
      );

      final street =
          _stringValue(place['text_ar']) ?? _stringValue(place['text']) ?? '';
      final houseNumber = _stringValue(place['address']) ??
          _stringValue(_propertyValue(place, 'address'));

      var district = '';
      var city = '';
      var governorate = '';

      final context = place['context'] ?? const [];
      for (final item in context) {
        final id = _stringValue(item['id']) ?? '';
        final text =
            _stringValue(item['text_ar']) ?? _stringValue(item['text']) ?? '';

        if (text.isEmpty) {
          continue;
        }

        if (id.contains('neighborhood') || id.contains('locality')) {
          district = text;
        } else if (id.contains('place')) {
          city = text;
        } else if (id.contains('region')) {
          governorate = text;
        }
      }

      final parts = [street, district, city, governorate]
          .where((value) => value.isNotEmpty)
          .toList(growable: false);
      final fallbackAddress = _stringValue(place['place_name_ar']) ??
          _stringValue(place['place_name']);
      final address = parts.isEmpty ? fallbackAddress : parts.join(' - ');
      if (address == null || address.isEmpty) {
        return null;
      }

      return LocationAddressDetails(
        address: address,
        houseNumber: houseNumber,
      );
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'location_service.getAddressDetails',
        error: error,
        stack: stack,
      );
      return null;
    }
  }

  static Future<String?> getAddress({
    required double lat,
    required double lng,
    required String token,
  }) async {
    final details = await getAddressDetails(
      lat: lat,
      lng: lng,
      token: token,
    );
    return details?.address;
  }

  static dynamic _propertyValue(Map<dynamic, dynamic> data, String key) {
    final properties = data['properties'];
    if (properties is Map) {
      return properties[key];
    }
    return null;
  }

  static String? _stringValue(dynamic value) {
    final text = value?.toString().trim();
    if (text == null || text.isEmpty || text == 'null') {
      return null;
    }
    return text;
  }
}
