import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../core/config/env.dart';
import '../core/services/error_logger.dart';
import '../core/location/location_service.dart';
import '../core/theme/app_theme.dart';

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
  final MapController _controller = MapController();
  final TextEditingController _addressController = TextEditingController();
  final TextEditingController _houseNumberController = TextEditingController();
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();

  AnimationController? _moveController;

  String _statusMessage = 'جارٍ تحديد موقعك...';
  bool loadingAddress = false;
  bool locatingUser = false;
  bool _satelliteMode = false;
  bool _detailsUnlocked = false;
  int _addressRequestId = 0;

  LatLng? _selectedPoint;
  LatLng? _currentLocationPoint;

  String get _mapboxToken => AppEnv.mapboxToken;

  @override
  void initState() {
    super.initState();
    if (widget.initialLat != null && widget.initialLng != null) {
      _selectedPoint = LatLng(widget.initialLat!, widget.initialLng!);
    }
    _addressController.text = widget.initialAddress?.trim() ?? '';
    _houseNumberController.text = widget.initialHouseNumber?.trim() ?? '';
    _nameController.text = widget.initialCustomerName?.trim() ?? '';
    _phoneController.text = widget.initialCustomerPhone?.trim() ?? '';
    if (_selectedPoint != null) {
      _statusMessage = 'تم تحميل الموقع الحالي. اضغط تأكيد العنوان للمتابعة.';
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }

      final initialPoint = _selectedPoint;
      if (initialPoint != null) {
        _controller.move(initialPoint, 16.5);
        if (_addressController.text.isEmpty) {
          setState(() {
            loadingAddress = true;
            _statusMessage = 'جارٍ تحميل العنوان الحالي...';
          });
          unawaited(_resolveAddress(initialPoint));
        }
        return;
      }

      unawaited(_centerOnUserLocation());
    });
  }

  @override
  void dispose() {
    _moveController?.dispose();
    _addressController.dispose();
    _houseNumberController.dispose();
    _nameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  Future<void> _centerOnUserLocation() async {
    if (locatingUser) {
      return;
    }

    setState(() => locatingUser = true);

    try {
      final point = await _getCurrentLocation();
      if (!mounted) {
        return;
      }

      if (point == null) {
        setState(() {
          locatingUser = false;
          _statusMessage =
              'فعّل الموقع أو اضغط على الخريطة لتحديد العنوان يدويًا.';
        });
        return;
      }

      await _selectPoint(
        point,
        markAsCurrentLocation: true,
        statusMessage: 'جارٍ تحديد عنوانك...',
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

  Future<void> _selectPoint(
    LatLng point, {
    bool markAsCurrentLocation = false,
    String statusMessage = 'جارٍ تحديد العنوان...',
  }) async {
    _setControllerValue(_addressController, '');
    _setControllerValue(_houseNumberController, '');

    setState(() {
      if (markAsCurrentLocation) {
        _currentLocationPoint = point;
      }
      _selectedPoint = point;
      loadingAddress = true;
      _detailsUnlocked = false;
      _statusMessage = statusMessage;
    });

    await _animateTo(point, zoom: 16.5);
    await _resolveAddress(point);
  }

  Future<LatLng?> _getCurrentLocation() async {
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

    final position = await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.high,
    );

    return LatLng(position.latitude, position.longitude);
  }

  Future<void> _animateTo(
    LatLng target, {
    double? zoom,
  }) async {
    try {
      final beginCenter = _controller.camera.center;
      final beginZoom = _controller.camera.zoom;
      final endZoom = zoom ?? beginZoom;

      _moveController?.dispose();
      final controller = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 520),
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
      _controller.move(target, zoom ?? 16.5);
    }
  }

  Future<void> _resolveAddress(LatLng point) async {
    final requestId = ++_addressRequestId;
    final details = await LocationService.getAddressDetails(
      lat: point.latitude,
      lng: point.longitude,
      token: _mapboxToken,
    );

    if (!mounted || requestId != _addressRequestId) {
      return;
    }

    if (details == null) {
      _setControllerValue(_addressController, '');
      setState(() {
        loadingAddress = false;
        _statusMessage =
            'تعذر تحديد العنوان تلقائيًا. يمكنك تأكيد الموقع ثم كتابة العنوان يدويًا.';
      });
      return;
    }

    _setControllerValue(_addressController, details.address);
    if ((details.houseNumber ?? '').trim().isNotEmpty) {
      _setControllerValue(_houseNumberController, details.houseNumber!.trim());
    }

    setState(() {
      loadingAddress = false;
      _statusMessage = _detailsUnlocked
          ? 'أكمل تفاصيل التوصيل ثم احفظ العنوان.'
          : 'تم تحديد الموقع. اضغط تأكيد العنوان للمتابعة.';
    });
  }

  Future<void> _handleTap(LatLng point) async {
    await _selectPoint(point);
  }

  void _unlockDetails() {
    if (_selectedPoint == null || loadingAddress) {
      return;
    }

    FocusScope.of(context).unfocus();
    setState(() {
      _detailsUnlocked = true;
      _statusMessage = 'أكمل تفاصيل التوصيل ثم احفظ العنوان.';
    });
  }

  void _confirm() {
    if (_selectedPoint == null || loadingAddress || !_detailsUnlocked) {
      return;
    }

    final fullAddress = _addressController.text.trim();
    if (fullAddress.isEmpty) {
      _showSnack('اكتب عنوان التوصيل قبل الحفظ.');
      return;
    }

    final customerName = _nameController.text.trim();
    if (customerName.isEmpty) {
      _showSnack('اكتب الاسم أولاً.');
      return;
    }

    final customerPhone = _phoneController.text.trim();
    if (customerPhone.length < 8) {
      _showSnack('رقم الهاتف غير صحيح.');
      return;
    }

    Navigator.pop(context, {
      'lat': _selectedPoint!.latitude,
      'lng': _selectedPoint!.longitude,
      'fullAddress': fullAddress,
      'houseNumber': _houseNumberController.text.trim(),
      'customerName': customerName,
      'customerPhone': customerPhone,
    });
  }

  void _toggleSatelliteMode() {
    setState(() => _satelliteMode = !_satelliteMode);
  }

  void _setControllerValue(TextEditingController controller, String value) {
    if (controller.text == value) {
      return;
    }

    controller.value = controller.value.copyWith(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
      composing: TextRange.empty,
    );
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Scaffold(
      appBar: AppBar(title: const Text('عنوان التوصيل')),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _controller,
            options: MapOptions(
              initialCenter: _selectedPoint ?? const LatLng(30.0444, 31.2357),
              initialZoom: _selectedPoint == null ? 13 : 16.5,
              onTap: (_, point) => _handleTap(point),
            ),
            children: [
              TileLayer(
                urlTemplate: _satelliteMode
                    ? 'https://api.mapbox.com/styles/v1/mapbox/satellite-streets-v12/tiles/256/{z}/{x}/{y}@2x?access_token=$_mapboxToken'
                    : 'https://api.mapbox.com/styles/v1/mapbox/streets-v12/tiles/256/{z}/{x}/{y}@2x?access_token=$_mapboxToken',
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
              if (_selectedPoint != null)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: _selectedPoint!,
                      width: 48,
                      height: 48,
                      child: const _DeliveryLocationMarker(),
                    ),
                  ],
                ),
            ],
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
                      borderRadius: BorderRadius.circular(22),
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
                            if (loadingAddress)
                              const SizedBox(
                                width: 18,
                                height: 18,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              ),
                            const Spacer(),
                            Text(
                              _detailsUnlocked ? 'تفاصيل التوصيل' : 'حدد موقعك',
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
                        AnimatedSize(
                          duration: const Duration(milliseconds: 240),
                          curve: Curves.easeOutCubic,
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 220),
                            switchInCurve: Curves.easeOutCubic,
                            switchOutCurve: Curves.easeInCubic,
                            child: !_detailsUnlocked
                                ? const SizedBox.shrink(
                                    key: ValueKey('delivery-details-hidden'),
                                  )
                                : Column(
                                    key: const ValueKey('delivery-details'),
                                    children: [
                                      const SizedBox(height: 14),
                                      TextField(
                                        controller: _addressController,
                                        textAlign: TextAlign.right,
                                        minLines: 2,
                                        maxLines: 3,
                                        decoration: const InputDecoration(
                                          labelText: 'عنوان التوصيل',
                                          hintText:
                                              'اكتب العنوان إذا لم يتم التقاطه تلقائيًا',
                                          prefixIcon: Icon(
                                            Icons.location_on_outlined,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(height: 12),
                                      TextField(
                                        controller: _nameController,
                                        textAlign: TextAlign.right,
                                        decoration: const InputDecoration(
                                          labelText: 'الاسم',
                                          hintText: 'اسم مستلم الطلب',
                                          prefixIcon: Icon(Icons.person_outline),
                                        ),
                                      ),
                                      const SizedBox(height: 12),
                                      TextField(
                                        controller: _phoneController,
                                        textAlign: TextAlign.right,
                                        keyboardType: TextInputType.phone,
                                        decoration: const InputDecoration(
                                          labelText: 'رقم الهاتف',
                                          hintText: '01xxxxxxxxx',
                                          prefixIcon: Icon(Icons.phone_outlined),
                                        ),
                                      ),
                                      const SizedBox(height: 12),
                                      TextField(
                                        controller: _houseNumberController,
                                        textAlign: TextAlign.right,
                                        decoration: const InputDecoration(
                                          labelText: 'رقم البيت',
                                          hintText:
                                              'مثال: شقة 12 - الدور الثالث',
                                          prefixIcon: Icon(Icons.home_outlined),
                                        ),
                                      ),
                                    ],
                                  ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _selectedPoint == null || loadingAddress
                          ? null
                          : (_detailsUnlocked ? _confirm : _unlockDetails),
                      icon: Icon(
                        _detailsUnlocked
                            ? Icons.done_rounded
                            : Icons.check_circle_outline_rounded,
                      ),
                      label: Text(
                        _detailsUnlocked ? 'حفظ العنوان' : 'تأكيد العنوان',
                      ),
                    ),
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
      size: 48,
      color: AppTheme.primary,
    );
  }
}
