import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/services/error_logger.dart';
import '../../core/theme/app_theme.dart';
import '../../services/profile_service.dart';
import '../home_page.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage>
    with SingleTickerProviderStateMixin {
  final supabase = Supabase.instance.client;
  final ProfileService _profileService = ProfileService();

  final emailCtrl = TextEditingController();
  final passCtrl = TextEditingController();
  final nameCtrl = TextEditingController();
  final phoneCtrl = TextEditingController();

  late TabController tab;
  bool loading = false;

  @override
  void initState() {
    super.initState();
    tab = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    tab.dispose();
    emailCtrl.dispose();
    passCtrl.dispose();
    nameCtrl.dispose();
    phoneCtrl.dispose();
    super.dispose();
  }

  // ================= LOGIN =================

  Future<void> _login() async {
    if (emailCtrl.text.trim().isEmpty || passCtrl.text.trim().isEmpty) {
      _snack('اكتب البريد الإلكتروني وكلمة السر.');
      return;
    }

    setState(() => loading = true);
    try {
      await supabase.auth.signInWithPassword(
        email: emailCtrl.text.trim(),
        password: passCtrl.text.trim(),
      );

      await _profileService.getOrCreateProfile();

      if (!mounted) return;
      final navigator = Navigator.of(context);
      if (navigator.canPop()) {
        navigator.pop();
      } else {
        navigator.pushReplacement(
          MaterialPageRoute(
            builder: (_) => const HomePage(),
          ),
        );
      }
    } on AuthException catch (error, stack) {
      await ErrorLogger.logError(
        module: 'login_page.login',
        error: error,
        stack: stack,
      );
      _snack(ErrorLogger.userMessage);
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'login_page.login',
        error: error,
        stack: stack,
      );
      _snack(ErrorLogger.userMessage);
    } finally {
      if (mounted) {
        setState(() => loading = false);
      }
    }
  }

  // ================= REGISTER =================

  Future<void> _register() async {
    if (nameCtrl.text.isEmpty || phoneCtrl.text.isEmpty) {
      _snack('كمّل البيانات');
      return;
    }

    setState(() => loading = true);

    try {
      await supabase.auth.signUp(
        email: emailCtrl.text.trim(),
        password: passCtrl.text.trim(),
      );

      if (supabase.auth.currentUser != null) {
        await _profileService.updateProfile(
          name: nameCtrl.text.trim(),
          phone: phoneCtrl.text.trim(),
        );
      }

      if (!mounted) {
        return;
      }

      if (supabase.auth.currentSession == null) {
        _snack('تم إنشاء الحساب. راجع بريدك ثم سجّل الدخول.');
        tab.animateTo(0);
      } else {
        _snack('تم إنشاء الحساب ✅');
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const HomePage()),
        );
      }
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'login_page.register',
        error: error,
        stack: stack,
      );
      _snack(ErrorLogger.userMessage);
    } finally {
      if (mounted) {
        setState(() => loading = false);
      }
    }
  }

  // ================= UI =================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text('الحساب'),
      ),
      body: Column(
        children: [
          TabBar(
            controller: tab,
            labelColor: AppTheme.text,
            indicatorColor: AppTheme.primary,
            tabs: const [
              Tab(text: 'تسجيل دخول'),
              Tab(text: 'حساب جديد'),
            ],
          ),
          Expanded(
            child: TabBarView(
              controller: tab,
              children: [
                _loginView(),
                _registerView(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _loginView() {
    return _form([
      _field(emailCtrl, 'الإيميل'),
      _field(passCtrl, 'كلمة السر', pass: true),
      _button('دخول', _login),
    ]);
  }

  Widget _registerView() {
    return _form([
      _field(nameCtrl, 'الاسم'),
      _field(phoneCtrl, 'رقم التليفون'),
      _field(emailCtrl, 'الإيميل'),
      _field(passCtrl, 'كلمة السر', pass: true),
      _button('إنشاء حساب', _register),
    ]);
  }

  Widget _form(List<Widget> children) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: AppTheme.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(24),
            ),
            child: const Icon(
              Icons.delivery_dining_rounded,
              size: 38,
              color: AppTheme.primary,
            ),
          ),
          const SizedBox(height: 18),
          ...children,
        ],
      ),
    );
  }

  Widget _field(TextEditingController c, String hint, {bool pass = false}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppTheme.border),
      ),
      child: TextField(
        controller: c,
        obscureText: pass,
        textAlign: TextAlign.right,
        keyboardType: hint.contains('تليفون') ? TextInputType.phone : null,
        decoration: InputDecoration(
          hintText: hint,
          border: InputBorder.none,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        ),
      ),
    );
  }

  Widget _button(String text, VoidCallback onTap) {
    return SizedBox(
      width: double.infinity,
      height: 48,
      child: ElevatedButton(
        onPressed: loading ? null : onTap,
        style: ElevatedButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
        ),
        child: loading
            ? const CircularProgressIndicator(color: Colors.white)
            : Text(text),
      ),
    );
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}
