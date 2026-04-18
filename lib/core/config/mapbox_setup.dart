import 'mapbox_setup_stub.dart' if (dart.library.io) 'mapbox_setup_mobile.dart'
    as mapbox_setup_impl;

Future<bool> configureMapboxAccessToken(String token) {
  return mapbox_setup_impl.configureMapboxAccessToken(token);
}
