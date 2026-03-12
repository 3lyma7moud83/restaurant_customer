class LocationResult {
  final double lat;
  final double lng;
  final String? address;

  const LocationResult({
    required this.lat,
    required this.lng,
    this.address,
  });
}
