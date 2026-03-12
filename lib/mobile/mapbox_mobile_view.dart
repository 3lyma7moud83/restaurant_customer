import 'package:flutter/material.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
import 'package:geolocator/geolocator.dart' as geo;

class MapboxMobileView extends StatefulWidget {
  final double lat;
  final double lng;
  final Function(double lat, double lng) onMove;

  const MapboxMobileView({
    super.key,
    required this.lat,
    required this.lng,
    required this.onMove,
  });

  @override
  State<MapboxMobileView> createState() => _MapboxMobileViewState();
}

class _MapboxMobileViewState extends State<MapboxMobileView> {
  MapboxMap? _mapboxMap;
  bool satellite = false;

  // ================= MOVE TO USER LOCATION =================
  Future<void> _moveToUserLocation() async {
    geo.LocationPermission permission = await geo.Geolocator.checkPermission();

    if (permission == geo.LocationPermission.denied) {
      permission = await geo.Geolocator.requestPermission();
    }

    if (permission == geo.LocationPermission.denied ||
        permission == geo.LocationPermission.deniedForever) {
      return;
    }

    final geo.Position pos = await geo.Geolocator.getCurrentPosition(
      desiredAccuracy: geo.LocationAccuracy.high,
    );

    _mapboxMap?.flyTo(
      CameraOptions(
        center: Point(
          coordinates: Position(pos.longitude, pos.latitude),
        ),
        zoom: 16,
      ),
      MapAnimationOptions(duration: 600),
    );
  }

  // ================= TOGGLE MAP STYLE =================
  Future<void> _toggleStyle() async {
    satellite = !satellite;

    await _mapboxMap?.loadStyleURI(
      satellite ? MapboxStyles.SATELLITE_STREETS : MapboxStyles.MAPBOX_STREETS,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // ================= MAP =================
        MapWidget(
          cameraOptions: CameraOptions(
            center: Point(
              coordinates: Position(widget.lng, widget.lat),
            ),
            zoom: 15,
          ),
          onMapCreated: (controller) {
            _mapboxMap = controller;
          },
          onCameraChangeListener: (data) {
            final center = data.cameraState.center.coordinates;
            widget.onMove(
              center.lat.toDouble(),
              center.lng.toDouble(),
            );
          },
        ),

        // ================= CENTER PIN =================
        const Center(
          child: Icon(
            Icons.location_pin,
            size: 46,
            color: Colors.red,
          ),
        ),

        // ================= MAP BUTTONS =================
        Positioned(
          right: 12,
          top: MediaQuery.of(context).padding.top + 12,
          child: Column(
            children: [
              _MapActionButton(
                icon: Icons.my_location,
                onTap: _moveToUserLocation,
              ),
              const SizedBox(height: 10),
              _MapActionButton(
                icon: Icons.layers_outlined,
                onTap: _toggleStyle,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/* ================= SMALL BUTTON ================= */

class _MapActionButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _MapActionButton({
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      elevation: 4,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Icon(icon, size: 22),
        ),
      ),
    );
  }
}
