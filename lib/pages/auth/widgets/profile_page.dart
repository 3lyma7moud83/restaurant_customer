import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '/core/services/error_logger.dart';
import '/core/theme/app_theme.dart';
import '/core/ui/input_focus_guard.dart';
import '/core/ui/app_snackbar.dart';
import '/cart/select_address_page.dart';
import '/services/customer_address_service.dart';
import '/services/profile_service.dart';

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  final ProfileService _profileService = ProfileService();

  final TextEditingController _nameCtrl = TextEditingController();
  final TextEditingController _phoneCtrl = TextEditingController();
  final TextEditingController _addressCtrl = TextEditingController();
  final TextEditingController _houseCtrl = TextEditingController();

  String _originalName = '';
  String _originalPhone = '';
  String _originalAddress = '';
  String _originalHouse = '';
  double? _selectedLat;
  double? _selectedLng;
  double? _originalLat;
  double? _originalLng;

  bool _loading = true;
  bool _savingProfile = false;
  bool _savingAddress = false;
  bool _contentVisible = kIsWeb;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _addressCtrl.dispose();
    _houseCtrl.dispose();
    super.dispose();
  }

  bool get _hasProfileChanges =>
      _nameCtrl.text.trim() != _originalName ||
      _phoneCtrl.text.trim() != _originalPhone;

  bool get _hasAddressChanges =>
      _addressCtrl.text.trim() != _originalAddress ||
      _houseCtrl.text.trim() != _originalHouse ||
      !_sameCoordinate(_selectedLat, _originalLat) ||
      !_sameCoordinate(_selectedLng, _originalLng);

  Future<void> _loadProfile() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final profileFuture = _profileService.getOrCreateProfile();
      final addressFuture = CustomerAddressService.getPrimaryAddress();
      final profile = await profileFuture;
      final address = await addressFuture;

      if (!mounted) {
        return;
      }

      _setControllerValue(_nameCtrl, (profile['name'] ?? '').toString().trim());
      _setControllerValue(
          _phoneCtrl, (profile['phone'] ?? '').toString().trim());

      _setControllerValue(_addressCtrl, address?.primaryAddress ?? '');
      _setControllerValue(_houseCtrl, address?.houseApartmentNo ?? '');
      _selectedLat = address?.lat;
      _selectedLng = address?.lng;

      _originalName = _nameCtrl.text.trim();
      _originalPhone = _phoneCtrl.text.trim();
      _originalAddress = _addressCtrl.text.trim();
      _originalHouse = _houseCtrl.text.trim();
      _originalLat = _selectedLat;
      _originalLng = _selectedLng;
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'profile_page.loadProfile',
        error: error,
        stack: stack,
      );
      _error = ErrorLogger.userMessage;
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _loading = false;
      _contentVisible = true;
    });
  }

  Future<void> _saveProfile() async {
    if (_savingProfile || !_hasProfileChanges) {
      return;
    }

    final name = _nameCtrl.text.trim();
    final phone = _phoneCtrl.text.trim();
    if (name.isEmpty) {
      _toast('الاسم لا يمكن أن يكون فارغًا.');
      return;
    }
    if (phone.length < 8) {
      _toast('رقم الهاتف غير صحيح.');
      return;
    }

    setState(() => _savingProfile = true);
    try {
      await _profileService.updateProfile(name: name, phone: phone);
      _originalName = name;
      _originalPhone = phone;
      _toast('تم حفظ بيانات الحساب.');
    } catch (_) {
      _toast(ErrorLogger.userMessage);
    } finally {
      if (mounted) {
        setState(() => _savingProfile = false);
      }
    }
  }

  Future<void> _saveAddress() async {
    if (_savingAddress || !_hasAddressChanges) {
      return;
    }

    final address = _addressCtrl.text.trim();
    final house = _houseCtrl.text.trim();

    if (address.isEmpty) {
      _toast('اكتب العنوان الأساسي.');
      return;
    }
    if (house.isEmpty) {
      _toast('اكتب رقم البيت / الشقة.');
      return;
    }
    if (_selectedLat == null || _selectedLng == null) {
      _toast('حدد موقع العنوان من الخريطة أولاً.');
      return;
    }

    setState(() => _savingAddress = true);
    try {
      final saved = await CustomerAddressService.savePrimaryAddress(
        primaryAddress: address,
        houseApartmentNo: house,
        area: '',
        additionalNotes: '',
        lat: _selectedLat,
        lng: _selectedLng,
      );

      _setControllerValue(_addressCtrl, saved.primaryAddress);
      _setControllerValue(_houseCtrl, saved.houseApartmentNo);
      _selectedLat = saved.lat ?? _selectedLat;
      _selectedLng = saved.lng ?? _selectedLng;

      _originalAddress = saved.primaryAddress;
      _originalHouse = saved.houseApartmentNo;
      _originalLat = _selectedLat;
      _originalLng = _selectedLng;

      _toast('تم حفظ العنوان الأساسي.');
    } catch (_) {
      _toast(ErrorLogger.userMessage);
    } finally {
      if (mounted) {
        setState(() => _savingAddress = false);
      }
    }
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

  Future<void> _openAddressPicker() async {
    if (_savingAddress) {
      return;
    }

    await InputFocusGuard.prepareForUiTransition(context: context);
    if (!mounted) {
      return;
    }

    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => SelectAddressPage(
        initialLat: _selectedLat,
        initialLng: _selectedLng,
        initialAddress: _addressCtrl.text.trim(),
        initialHouseNumber: _houseCtrl.text.trim(),
        initialCustomerName: _nameCtrl.text.trim(),
        initialCustomerPhone: _phoneCtrl.text.trim(),
      ),
    );

    if (result == null || !mounted) {
      return;
    }

    final lat = (result['lat'] as num?)?.toDouble();
    final lng = (result['lng'] as num?)?.toDouble();
    final fullAddress =
        (result['address'] ?? result['fullAddress'] ?? '').toString().trim();
    final houseNumber = (result['house_number'] ?? result['houseNumber'] ?? '')
        .toString()
        .trim();

    if (lat == null || lng == null || fullAddress.isEmpty) {
      _toast('تعذر اعتماد الموقع المحدد، حاول مرة أخرى.');
      return;
    }

    _setControllerValue(_addressCtrl, fullAddress);
    _setControllerValue(_houseCtrl, houseNumber);
    setState(() {
      _selectedLat = lat;
      _selectedLng = lng;
    });
  }

  bool _sameCoordinate(double? first, double? second) {
    if (first == null || second == null) {
      return first == second;
    }
    return (first - second).abs() < 0.000001;
  }

  void _toast(String message) {
    AppSnackBar.show(context, message: message);
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;
    return Scaffold(
      appBar: AppBar(
        title: const Text('الملف الشخصي'),
        centerTitle: true,
        actions: [
          IconButton(
            onPressed: _loading ? null : _loadProfile,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _errorView()
              : AnimatedPadding(
                  duration: AppTheme.sectionTransitionDuration,
                  curve: AppTheme.emphasizedCurve,
                  padding: EdgeInsets.only(bottom: viewInsets),
                  child: AnimatedOpacity(
                    opacity: _contentVisible ? 1 : 0,
                    duration: kIsWeb
                        ? Duration.zero
                        : const Duration(milliseconds: 240),
                    curve: Curves.easeOutCubic,
                    child: RefreshIndicator(
                      onRefresh: _loadProfile,
                      child: ListView(
                        physics: AppTheme.bouncingScrollPhysics,
                        keyboardDismissBehavior:
                            ScrollViewKeyboardDismissBehavior.onDrag,
                        padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
                        children: [
                          _ProfileHeroCard(
                            name: _nameCtrl.text.trim(),
                            phone: _phoneCtrl.text.trim(),
                          ),
                          const SizedBox(height: 14),
                          _SectionPanel(
                            title: 'بيانات الحساب',
                            subtitle: 'بياناتك الأساسية المستخدمة في الطلبات.',
                            child: Column(
                              children: [
                                _ProfileTextField(
                                  controller: _nameCtrl,
                                  label: 'الاسم',
                                  hint: 'اسمك الكامل',
                                  icon: Icons.person_outline_rounded,
                                ),
                                const SizedBox(height: 10),
                                _ProfileTextField(
                                  controller: _phoneCtrl,
                                  label: 'رقم الهاتف',
                                  hint: 'مثال: 01000000000',
                                  icon: Icons.phone_outlined,
                                  keyboardType: TextInputType.phone,
                                ),
                                const SizedBox(height: 14),
                                SizedBox(
                                  width: double.infinity,
                                  child: ElevatedButton.icon(
                                    onPressed:
                                        (!_hasProfileChanges || _savingProfile)
                                            ? null
                                            : _saveProfile,
                                    icon: _savingProfile
                                        ? const SizedBox(
                                            width: 16,
                                            height: 16,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              color: Colors.white,
                                            ),
                                          )
                                        : const Icon(Icons.save_outlined),
                                    label: const Text('حفظ بيانات الحساب'),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 14),
                          _SectionPanel(
                            title: 'العنوان الأساسي',
                            subtitle:
                                'يُستخدم تلقائيًا في الطلبات ويمكن تعديله في أي وقت.',
                            child: Column(
                              children: [
                                _ProfileTextField(
                                  controller: _addressCtrl,
                                  label: 'العنوان الأساسي',
                                  hint: 'اختر العنوان من الخريطة',
                                  icon: Icons.location_on_outlined,
                                  minLines: 2,
                                  maxLines: 3,
                                  readOnly: true,
                                  onTap: _openAddressPicker,
                                  suffixIcon: IconButton(
                                    onPressed: _openAddressPicker,
                                    icon: const Icon(Icons.map_outlined),
                                  ),
                                ),
                                const SizedBox(height: 10),
                                _ProfileTextField(
                                  controller: _houseCtrl,
                                  label: 'رقم البيت / الشقة',
                                  hint: 'مثال: عمارة 7 - شقة 12',
                                  icon: Icons.home_outlined,
                                ),
                                const SizedBox(height: 10),
                                Align(
                                  alignment: Alignment.centerRight,
                                  child: Text(
                                    _selectedLat == null || _selectedLng == null
                                        ? 'لم يتم تحديد موقع الخريطة بعد.'
                                        : 'الموقع مضبوط على الخريطة (${_selectedLat!.toStringAsFixed(5)}, ${_selectedLng!.toStringAsFixed(5)})',
                                    textAlign: TextAlign.right,
                                    style: const TextStyle(
                                      color: Color(0xFF667085),
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 14),
                                SizedBox(
                                  width: double.infinity,
                                  child: ElevatedButton.icon(
                                    onPressed:
                                        (!_hasAddressChanges || _savingAddress)
                                            ? null
                                            : _saveAddress,
                                    icon: _savingAddress
                                        ? const SizedBox(
                                            width: 16,
                                            height: 16,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              color: Colors.white,
                                            ),
                                          )
                                        : const Icon(Icons.location_on_rounded),
                                    label: const Text('حفظ العنوان الأساسي'),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
    );
  }

  Widget _errorView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _error ?? ErrorLogger.userMessage,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xFFB42318)),
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: _loadProfile,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('إعادة المحاولة'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProfileHeroCard extends StatelessWidget {
  const _ProfileHeroCard({
    required this.name,
    required this.phone,
  });

  final String name;
  final String phone;

  @override
  Widget build(BuildContext context) {
    final safeName = name.isEmpty ? 'حساب العميل' : name;
    final safePhone = phone.isEmpty ? 'أضف رقم الهاتف' : phone;
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFF5C186), Color(0xFFF28C28)],
        ),
        boxShadow: [
          BoxShadow(
            color: AppTheme.primary.withValues(alpha: 0.26),
            blurRadius: 22,
            offset: const Offset(0, 11),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  safeName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  safePhone,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    color: Color(0xFFFDF3E7),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          Container(
            width: 62,
            height: 62,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.23),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white.withValues(alpha: 0.32)),
            ),
            child: const Icon(
              Icons.person_rounded,
              color: Colors.white,
              size: 32,
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionPanel extends StatelessWidget {
  const _SectionPanel({
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: AppTheme.border.withValues(alpha: 0.92)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x12000000),
            blurRadius: 16,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            title,
            textAlign: TextAlign.right,
            style: const TextStyle(
              color: AppTheme.text,
              fontSize: 16,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            textAlign: TextAlign.right,
            style: const TextStyle(
              color: Color(0xFF667085),
              fontWeight: FontWeight.w600,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

class _ProfileTextField extends StatelessWidget {
  const _ProfileTextField({
    required this.controller,
    required this.label,
    required this.hint,
    required this.icon,
    this.keyboardType,
    this.minLines = 1,
    this.maxLines = 1,
    this.readOnly = false,
    this.onTap,
    this.suffixIcon,
  });

  final TextEditingController controller;
  final String label;
  final String hint;
  final IconData icon;
  final TextInputType? keyboardType;
  final int minLines;
  final int maxLines;
  final bool readOnly;
  final VoidCallback? onTap;
  final Widget? suffixIcon;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      onTapOutside: (_) => InputFocusGuard.dismiss(),
      onTap: onTap,
      readOnly: readOnly,
      textAlign: TextAlign.right,
      keyboardType: keyboardType,
      minLines: minLines,
      maxLines: maxLines,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: Icon(icon),
        suffixIcon: suffixIcon,
      ),
    );
  }
}
