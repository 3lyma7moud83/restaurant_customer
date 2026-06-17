import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../core/config/env.dart';
import '../core/location/location_service.dart';
import '../core/services/error_logger.dart';
import '../core/theme/app_theme.dart';
import '../core/ui/app_snackbar.dart';
import '../core/ui/input_focus_guard.dart';

class SelectAddressPage extends StatefulWidget {
  const SelectAddressPage({
    super.key,
    this.initialLat,
    this.initialLng,
    this.initialAddress,
    this.initialHouseNumber,
    this.initialCustomerName,
    this.initialCustomerPhone,
  });

  final double? initialLat;
  final double? initialLng;
  final String? initialAddress;
  final String? initialHouseNumber;
  final String? initialCustomerName;
  final String? initialCustomerPhone;

  @override
  State<SelectAddressPage> createState() => _SelectAddressPageState();
}

class _SelectAddressPageState extends State<SelectAddressPage>
    with TickerProviderStateMixin {
  static const double _goodAccuracyThresholdMeters = 50;
  static const Duration _mapIdleDebounce = Duration(milliseconds: 500);
  static const LatLng _fallbackCenter = LatLng(30.0444, 31.2357);

  final MapController _controller = MapController();
  final TextEditingController _addressController = TextEditingController();
  final TextEditingController _houseNumberController = TextEditingController();
  final FocusNode _addressFocusNode = FocusNode();
  final FocusNode _houseNumberFocusNode = FocusNode();
  final ValueNotifier<LatLng> _centerNotifier =
      ValueNotifier<LatLng>(_fallbackCenter);

  AnimationController? _moveController;
  Timer? _mapIdleTimer;

  String _statusMessage = 'جارٍ تحديد موقعك بدقة عالية...';
  bool loadingAddress = false;
  bool locatingUser = false;
  bool _satelliteMode = false;
  bool _mapIsMoving = false;
  int _addressRequestId = 0;

  LatLng? _selectedPoint;
  LatLng? _currentLocationPoint;
  double? _gpsAccuracyMeters;

  String? get _mapboxToken {
    try {
      final value = AppEnv.mapboxToken.trim();
      return value.isEmpty ? null : value;
    } catch (_) {
      return null;
    }
  }

  String get _tileUrlTemplate {
    final token = _mapboxToken;
    if (token == null) {
      return 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
    }

    return _satelliteMode
        ? 'https://api.mapbox.com/styles/v1/mapbox/satellite-streets-v12/tiles/256/{z}/{x}/{y}@2x?access_token=$token'
        : 'https://api.mapbox.com/styles/v1/mapbox/streets-v12/tiles/256/{z}/{x}/{y}@2x?access_token=$token';
  }

  String get _accuracyStatus {
    final accuracy = _gpsAccuracyMeters;
    if (accuracy == null) {
      return 'جاري القياس';
    }
    if (accuracy <= 10) {
      return 'ممتازة';
    }
    if (accuracy < _goodAccuracyThresholdMeters) {
      return 'جيدة';
    }
    return 'ضعيفة';
  }

  Color get _accuracyColor {
    final accuracy = _gpsAccuracyMeters;
    if (accuracy == null) {
      return const Color(0xFF667085);
    }
    if (accuracy <= 10) {
      return const Color(0xFF027A48);
    }
    if (accuracy < _goodAccuracyThresholdMeters) {
      return const Color(0xFFB54708);
    }
    return const Color(0xFFB42318);
  }

  bool get _hasGoodGpsFix =>
      _gpsAccuracyMeters != null &&
      _gpsAccuracyMeters! <= _goodAccuracyThresholdMeters;

  bool get _canConfirm =>
      _selectedPoint != null &&
      !loadingAddress &&
      !locatingUser &&
      !_mapIsMoving &&
      _hasGoodGpsFix &&
      _addressController.text.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    if (widget.initialLat != null && widget.initialLng != null) {
      _selectedPoint = LatLng(widget.initialLat!, widget.initialLng!);
      _centerNotifier.value = _selectedPoint!;
    }

    _addressController.text = widget.initialAddress?.trim() ?? '';
    _houseNumberController.text = widget.initialHouseNumber?.trim() ?? '';

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }

      final initialPoint = _selectedPoint;
      if (initialPoint != null) {
        _controller.move(initialPoint, 16.5);
      }
      unawaited(_centerOnUserLocation());
    });
  }

  @override
  void dispose() {
    _mapIdleTimer?.cancel();
    _moveController?.dispose();
    _controller.dispose();
    _addressController.dispose();
    _houseNumberController.dispose();
    _addressFocusNode.dispose();
    _houseNumberFocusNode.dispose();
    _centerNotifier.dispose();
    super.dispose();
  }

  Future<void> _centerOnUserLocation() async {
    if (locatingUser) {
      return;
    }

    setState(() {
      locatingUser = true;
      loadingAddress = true;
      _statusMessage = 'جارٍ الحصول على GPS Fix بدقة عالية...';
    });

    try {
      final position = await _getBestCurrentPosition();
      if (!mounted) {
        return;
      }

      if (position == null) {
        setState(() {
          loadingAddress = false;
          _statusMessage =
              'فعّل خدمة الموقع وامنح الصلاحية لتحديد عنوان التوصيل.';
        });
        return;
      }

      final point = LatLng(position.latitude, position.longitude);
      _currentLocationPoint = point;
      _gpsAccuracyMeters = position.accuracy.isFinite
          ? position.accuracy
          : _goodAccuracyThresholdMeters + 1;

      if (!_hasGoodGpsFix) {
        setState(() {
          _statusMessage = 'جاري تحسين دقة الموقع...';
        });
      }

      await _selectCenter(
        point,
        animate: true,
        statusMessage: _hasGoodGpsFix
            ? 'جارٍ تحميل عنوان موقعك الحالي...'
            : 'جاري تحسين دقة الموقع...',
      );
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'select_address_page.centerOnUserLocation',
        error: error,
        stack: stack,
      );
      if (mounted) {
        _showSnack(ErrorLogger.userMessage);
      }
    } finally {
      if (mounted) {
        setState(() => locatingUser = false);
      }
    }
  }

  Future<Position?> _getBestCurrentPosition() async {
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

    Position? best;

    try {
      best = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.bestForNavigation,
        timeLimit: const Duration(seconds: 12),
      );
      if (_isGoodPosition(best)) {
        return best;
      }
    } catch (_) {
      // Continue to the live stream below to avoid relying on a stale fix.
    }

    try {
      final stream = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          distanceFilter: 0,
          timeLimit: Duration(seconds: 18),
        ),
      );

      await for (final position in stream) {
        if (best == null || position.accuracy < best.accuracy) {
          best = position;
        }
        if (_isGoodPosition(position)) {
          return position;
        }
      }
    } on TimeoutException {
      return best;
    } catch (_) {
      return best;
    }

    return best;
  }

  bool _isGoodPosition(Position position) {
    return position.accuracy.isFinite &&
        position.accuracy <= _goodAccuracyThresholdMeters;
  }

  Future<void> _selectCenter(
    LatLng point, {
    bool animate = false,
    String statusMessage = 'جارٍ تحديد العنوان...',
  }) async {
    _mapIdleTimer?.cancel();
    _centerNotifier.value = point;

    setState(() {
      _selectedPoint = point;
      loadingAddress = true;
      _mapIsMoving = false;
      _statusMessage = statusMessage;
    });

    if (animate) {
      await _animateTo(point, zoom: 17);
    }
    await _resolveAddress(point);
  }

  Future<void> _animateTo(
    LatLng target, {
    double? zoom,
  }) async {
    if (kIsWeb) {
      _controller.move(target, zoom ?? 17);
      return;
    }

    try {
      final beginCenter = _controller.camera.center;
      final beginZoom = _controller.camera.zoom;
      final endZoom = zoom ?? beginZoom;

      _moveController?.dispose();
      final controller = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 420),
      );
      _moveController = controller;

      final curve = CurvedAnimation(
        parent: controller,
        curve: Curves.easeOutCubic,
      );
      final latTween = Tween<double>(
        begin: beginCenter.latitude,
        end: target.latitude,
      );
      final lngTween = Tween<double>(
        begin: beginCenter.longitude,
        end: target.longitude,
      );
      final zoomTween = Tween<double>(
        begin: beginZoom,
        end: endZoom,
      );

      controller.addListener(() {
        _controller.move(
          LatLng(
            latTween.evaluate(curve),
            lngTween.evaluate(curve),
          ),
          zoomTween.evaluate(curve),
        );
      });

      await controller.forward();
    } catch (_) {
      _controller.move(target, zoom ?? 17);
    }
  }

  Future<void> _resolveAddress(LatLng point) async {
    final token = _mapboxToken;
    if (token == null) {
      if (!mounted) {
        return;
      }
      setState(() {
        loadingAddress = false;
        _statusMessage =
            'تعذر تحميل عنوان تلقائيًا بسبب إعدادات الخرائط. اكتب العنوان يدويًا ثم أكد.';
      });
      return;
    }

    final requestId = ++_addressRequestId;
    final details = await LocationService.getAddressDetails(
      lat: point.latitude,
      lng: point.longitude,
      token: token,
    );

    if (!mounted || requestId != _addressRequestId) {
      return;
    }

    if (details == null) {
      _setControllerValue(
        _addressController,
        '',
        focusNode: _addressFocusNode,
        skipIfFocused: true,
      );
      setState(() {
        loadingAddress = false;
        _statusMessage =
            'تعذر تحديد العنوان تلقائيًا. يمكنك كتابة العنوان يدويًا بعد ثبات الموقع.';
      });
      return;
    }

    _setControllerValue(
      _addressController,
      details.address,
      focusNode: _addressFocusNode,
      skipIfFocused: true,
    );
    if ((details.houseNumber ?? '').trim().isNotEmpty) {
      _setControllerValue(
        _houseNumberController,
        details.houseNumber!.trim(),
        focusNode: _houseNumberFocusNode,
        skipIfFocused: true,
      );
    }

    setState(() {
      loadingAddress = false;
      _statusMessage = _hasGoodGpsFix
          ? 'تم تحديد الموقع. راجع العنوان ثم اضغط تأكيد الموقع.'
          : 'جاري تحسين دقة الموقع...';
    });
  }

  void _handlePositionChanged(MapCamera camera, bool hasGesture) {
    final center = camera.center;
    _centerNotifier.value = center;

    if (!hasGesture) {
      return;
    }

    _mapIdleTimer?.cancel();
    if (!_mapIsMoving && mounted) {
      setState(() {
        _mapIsMoving = true;
        loadingAddress = false;
        _statusMessage = 'حرّك الخريطة حتى يصبح الدبوس فوق موقع التسليم.';
      });
    }

    _mapIdleTimer = Timer(_mapIdleDebounce, () {
      if (!mounted) {
        return;
      }
      unawaited(_selectCenter(
        _centerNotifier.value,
        statusMessage: 'جارٍ تحميل عنوان الموقع المحدد...',
      ));
    });
  }

  Future<void> _confirm() async {
    if (!_hasGoodGpsFix) {
      _showSnack('جاري تحسين دقة الموقع...');
      return;
    }
    if (_selectedPoint == null || loadingAddress || _mapIsMoving) {
      return;
    }

    final address = _addressController.text.trim();
    if (address.isEmpty) {
      _showSnack('اكتب عنوان التوصيل قبل المتابعة.');
      return;
    }

    final houseNumber = _houseNumberController.text.trim();

    await InputFocusGuard.prepareForUiTransition(context: context);
    if (!mounted) {
      return;
    }
    Navigator.pop(context, {
      'address': address,
      'formatted_address': address,
      'lat': _selectedPoint!.latitude,
      'lng': _selectedPoint!.longitude,
      'latitude': _selectedPoint!.latitude,
      'longitude': _selectedPoint!.longitude,
      'accuracy': _gpsAccuracyMeters,
      'house_number': houseNumber,
      // Backward-compatible keys for existing consumers.
      'fullAddress': address,
      'houseNumber': houseNumber,
    });
  }

  void _toggleSatelliteMode() {
    setState(() => _satelliteMode = !_satelliteMode);
  }

  void _setControllerValue(
    TextEditingController controller,
    String value, {
    FocusNode? focusNode,
    bool skipIfFocused = false,
  }) {
    if (controller.text == value) {
      return;
    }
    if (skipIfFocused && focusNode?.hasFocus == true) {
      return;
    }

    controller.value = controller.value.copyWith(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
      composing: TextRange.empty,
    );
  }

  void _showSnack(String message) {
    AppSnackBar.show(context, message: message);
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final initialCenter = _selectedPoint ?? _fallbackCenter;

    return Scaffold(
      appBar: AppBar(title: const Text('عنوان التوصيل')),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _controller,
            options: MapOptions(
              initialCenter: initialCenter,
              initialZoom: _selectedPoint == null ? 13 : 17,
              onPositionChanged: _handlePositionChanged,
            ),
            children: [
              TileLayer(
                urlTemplate: _tileUrlTemplate,
              ),
              if (_currentLocationPoint != null)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: _currentLocationPoint!,
                      width: 28,
                      height: 28,
                      child: const _CurrentLocationMarker(),
                    ),
                  ],
                ),
            ],
          ),
          const IgnorePointer(
            child: Center(
              child: Padding(
                padding: EdgeInsets.only(bottom: 42),
                child: _DeliveryLocationMarker(),
              ),
            ),
          ),
          PositionedDirectional(
            top: 16,
            end: 16,
            child: Column(
              children: [
                _MapControlButton(
                  onPressed: locatingUser ? null : _centerOnUserLocation,
                  icon: locatingUser
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.my_location_rounded),
                ),
                const SizedBox(height: 10),
                _MapControlButton(
                  onPressed: _toggleSatelliteMode,
                  icon: Icon(
                    _satelliteMode
                        ? Icons.layers_clear_rounded
                        : Icons.satellite_alt_outlined,
                  ),
                ),
              ],
            ),
          ),
          PositionedDirectional(
            top: 16,
            start: 16,
            child: ValueListenableBuilder<LatLng>(
              valueListenable: _centerNotifier,
              builder: (context, center, _) {
                return _CoordinatePill(point: center);
              },
            ),
          ),
          PositionedDirectional(
            start: 16,
            end: 16,
            bottom: 20,
            child: AnimatedPadding(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              padding: EdgeInsets.only(bottom: bottomInset),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(18),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x14000000),
                          blurRadius: 18,
                          offset: Offset(0, 8),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Row(
                          children: [
                            if (loadingAddress || locatingUser)
                              const SizedBox(
                                width: 18,
                                height: 18,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              ),
                            const Spacer(),
                            Text(
                              'حدد موقعك',
                              style: TextStyle(
                                color: AppTheme.text,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _statusMessage,
                          textAlign: TextAlign.right,
                          style: const TextStyle(
                            color: Color(0xFF667085),
                            height: 1.45,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 12),
                        _AccuracySummary(
                          accuracyMeters: _gpsAccuracyMeters,
                          status: _accuracyStatus,
                          color: _accuracyColor,
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _addressController,
                          focusNode: _addressFocusNode,
                          onTapOutside: (_) => InputFocusGuard.dismiss(),
                          textAlign: TextAlign.right,
                          minLines: 2,
                          maxLines: 3,
                          onChanged: (_) => setState(() {}),
                          decoration: const InputDecoration(
                            labelText: 'العنوان الحالي',
                            hintText:
                                'اكتب العنوان إذا لم يتم التقاطه تلقائيًا',
                            prefixIcon: Icon(Icons.location_on_outlined),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _houseNumberController,
                          focusNode: _houseNumberFocusNode,
                          onTapOutside: (_) => InputFocusGuard.dismiss(),
                          textAlign: TextAlign.right,
                          decoration: const InputDecoration(
                            labelText: 'رقم العمارة',
                            hintText: 'مثال: 12',
                            prefixIcon: Icon(Icons.home_outlined),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Column(
                    children: [
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed:
                              locatingUser ? null : _centerOnUserLocation,
                          icon: const Icon(Icons.my_location_rounded),
                          label: const Text('استخدام موقعي الحالي'),
                        ),
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: _canConfirm ? _confirm : null,
                          icon: const Icon(Icons.done_rounded),
                          label: const Text('تأكيد الموقع'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CoordinatePill extends StatelessWidget {
  const _CoordinatePill({required this.point});

  final LatLng point;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: const [
          BoxShadow(
            color: Color(0x14000000),
            blurRadius: 14,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        child: Text(
          '${point.latitude.toStringAsFixed(6)}, ${point.longitude.toStringAsFixed(6)}',
          textDirection: TextDirection.ltr,
          style: const TextStyle(
            color: AppTheme.text,
            fontSize: 12,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}

class _AccuracySummary extends StatelessWidget {
  const _AccuracySummary({
    required this.accuracyMeters,
    required this.status,
    required this.color,
  });

  final double? accuracyMeters;
  final String status;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final accuracyText = accuracyMeters == null
        ? 'جاري قياس الدقة'
        : 'دقة الموقع ${accuracyMeters!.round()}m';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.24)),
      ),
      child: Row(
        children: [
          Icon(Icons.gps_fixed_rounded, color: color, size: 20),
          const SizedBox(width: 8),
          Text(
            status,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w900,
            ),
          ),
          const Spacer(),
          Text(
            accuracyText,
            textAlign: TextAlign.right,
            style: const TextStyle(
              color: AppTheme.text,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _MapControlButton extends StatelessWidget {
  const _MapControlButton({
    required this.onPressed,
    required this.icon,
  });

  final VoidCallback? onPressed;
  final Widget icon;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      elevation: 3,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(16),
        child: SizedBox(
          width: 48,
          height: 48,
          child: Center(
            child: IconTheme(
              data: const IconThemeData(
                color: AppTheme.text,
                size: 22,
              ),
              child: icon,
            ),
          ),
        ),
      ),
    );
  }
}

class _CurrentLocationMarker extends StatelessWidget {
  const _CurrentLocationMarker();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppTheme.secondary.withValues(alpha: 0.22),
      ),
      padding: const EdgeInsets.all(5),
      child: Container(
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: AppTheme.secondary,
          border: Border.fromBorderSide(
            BorderSide(color: Colors.white, width: 2),
          ),
        ),
      ),
    );
  }
}

class _DeliveryLocationMarker extends StatelessWidget {
  const _DeliveryLocationMarker();

  @override
  Widget build(BuildContext context) {
    return const Icon(
      Icons.location_pin,
      size: 52,
      color: AppTheme.primary,
      shadows: [
        Shadow(
          color: Color(0x33000000),
          blurRadius: 10,
          offset: Offset(0, 4),
        ),
      ],
    );
  }
}
