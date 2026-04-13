import 'package:flutter/material.dart';
import '/core/services/error_logger.dart';
import '/core/theme/app_theme.dart';
import '/services/profile_service.dart';

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  final ProfileService service = ProfileService();

  final TextEditingController nameCtrl = TextEditingController();
  final TextEditingController phoneCtrl = TextEditingController();

  String originalName = '';
  String originalPhone = '';

  bool loading = true;
  bool saving = false;
  String? error;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  @override
  void dispose() {
    nameCtrl.dispose();
    phoneCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadProfile() async {
    setState(() {
      loading = true;
      error = null;
    });

    try {
      final data = await service.getOrCreateProfile();
      if (!mounted) return;

      nameCtrl.text = (data['name'] ?? '').toString();
      phoneCtrl.text = (data['phone'] ?? '').toString();

      originalName = nameCtrl.text;
      originalPhone = phoneCtrl.text;
    } catch (err, stack) {
      await ErrorLogger.logError(
        module: 'profile_page.loadProfile',
        error: err,
        stack: stack,
      );
      error = ErrorLogger.userMessage;
    }

    if (!mounted) return;
    setState(() => loading = false);
  }

  bool get hasChanges =>
      nameCtrl.text.trim() != originalName ||
      phoneCtrl.text.trim() != originalPhone;

  bool _validate() {
    final name = nameCtrl.text.trim();
    final phone = phoneCtrl.text.trim();

    if (name.isEmpty) {
      _toast('الاسم مينفعش يبقى فاضي');
      return false;
    }

    if (phone.isEmpty || phone.length < 8) {
      _toast('رقم التليفون غير صحيح');
      return false;
    }

    return true;
  }

  Future<void> _saveProfile() async {
    if (saving || !hasChanges) return;
    if (!_validate()) return;

    setState(() => saving = true);

    try {
      await service.updateProfile(
        name: nameCtrl.text.trim(),
        phone: phoneCtrl.text.trim(),
      );

      originalName = nameCtrl.text.trim();
      originalPhone = phoneCtrl.text.trim();

      _toast('تم الحفظ ✅');
    } catch (_) {
      _toast(ErrorLogger.userMessage);
    }

    if (!mounted) return;
    setState(() => saving = false);
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;

    return Scaffold(
      appBar: AppBar(
        title: const Text('الملف الشخصي'),
        centerTitle: true,
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : error != null
              ? _errorView()
              : AnimatedPadding(
                  duration: AppTheme.sectionTransitionDuration,
                  curve: AppTheme.emphasizedCurve,
                  padding: EdgeInsets.only(bottom: viewInsets),
                  child: RefreshIndicator(
                    onRefresh: _loadProfile,
                    child: ListView(
                      physics: AppTheme.bouncingScrollPhysics,
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      padding: const EdgeInsets.all(16),
                      children: [
                        _field('الاسم', nameCtrl),
                        _field(
                          'رقم التليفون',
                          phoneCtrl,
                          keyboard: TextInputType.phone,
                        ),
                        const SizedBox(height: 24),
                        SizedBox(
                          height: 48,
                          child: ElevatedButton(
                            onPressed:
                                (!hasChanges || saving) ? null : _saveProfile,
                            child: saving
                                ? const SizedBox(
                                    width: 22,
                                    height: 22,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Text('حفظ'),
                          ),
                        ),
                      ],
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
              error ?? ErrorLogger.userMessage,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.red),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _loadProfile,
              child: const Text('حاول تاني'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _field(
    String hint,
    TextEditingController controller, {
    TextInputType keyboard = TextInputType.text,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: const [
          BoxShadow(
            color: Colors.black12,
            blurRadius: 6,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: TextField(
        controller: controller,
        keyboardType: keyboard,
        decoration: InputDecoration(
          hintText: hint,
          border: InputBorder.none,
        ),
      ),
    );
  }
}
