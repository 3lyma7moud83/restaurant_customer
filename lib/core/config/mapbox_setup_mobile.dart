import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';

Future<bool> configureMapboxAccessToken(String token) async {
  MapboxOptions.setAccessToken(token);
  return true;
}
