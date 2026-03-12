import 'package:flutter/material.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';

class LocationResult {
  final double lat;
  final double lng;
  final String? address;

  LocationResult({
    required this.lat,
    required this.lng,
    this.address,
  });
}

class LocationPickerSheet extends StatefulWidget {
  const LocationPickerSheet({super.key});

  @override
  State<LocationPickerSheet> createState() => _LocationPickerSheetState();
}

class _LocationPickerSheetState extends State<LocationPickerSheet> {
  MapboxMap? map;
  late CameraOptions _camera;

  double lat = 30.0444; // القاهرة افتراضي
  double lng = 31.2357;

  @override
  void initState() {
    super.initState();
    _camera = CameraOptions(
      center: Point(coordinates: Position(lng, lat)),
      zoom: 15,
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.85,
        child: Stack(
          children: [
            // =====================
            // Map
            // =====================
            MapWidget(
              cameraOptions: _camera,
              onMapCreated: _onMapCreated,
              onCameraChangeListener: _onCameraChanged,
            ),

            // =====================
            // Pin في النص
            // =====================
            Center(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 36),
                child: Icon(
                  Icons.location_pin,
                  size: 48,
                  color: Colors.red.shade700,
                ),
              ),
            ),

            // =====================
            // Top Bar
            // =====================
            Positioned(
              top: 12,
              left: 16,
              right: 16,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: const [
                    BoxShadow(
                      blurRadius: 10,
                      color: Colors.black12,
                    ),
                  ],
                ),
                child: const Text(
                  'اسحب الخريطة حتى تطابق موقع التوصيل',
                  textAlign: TextAlign.center,
                ),
              ),
            ),

            // =====================
            // Confirm Button
            // =====================
            Positioned(
              left: 16,
              right: 16,
              bottom: 16,
              child: SizedBox(
                height: 50,
                child: ElevatedButton(
                  onPressed: _confirmLocation,
                  style: ElevatedButton.styleFrom(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: const Text('وصل هنا'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // =====================
  // Map Logic
  // =====================

  void _onMapCreated(MapboxMap controller) {
    map = controller;
  }

  void _onCameraChanged(CameraChangedEventData data) {
    final center = data.cameraState.center.coordinates;
    lat = center.lat.toDouble();
    lng = center.lng.toDouble();
  }

  void _confirmLocation() {
    Navigator.pop(
      context,
      LocationResult(
        lat: lat,
        lng: lng,
        address: null, // نضيف Reverse Geocoding بعدين
      ),
    );
  }
}
