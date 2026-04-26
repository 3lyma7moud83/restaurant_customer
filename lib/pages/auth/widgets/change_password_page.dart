import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/services/error_logger.dart';
import '../../../core/ui/app_snackbar.dart';
import '../../../core/ui/input_focus_guard.dart';

class ChangePasswordPage extends StatefulWidget {
  const ChangePasswordPage({super.key});

  @override
  State<ChangePasswordPage> createState() => _ChangePasswordPageState();
}

class _ChangePasswordPageState extends State<ChangePasswordPage> {
  final passCtrl = TextEditingController();
  bool loading = false;

  @override
  void dispose() {
    passCtrl.dispose();
    super.dispose();
  }

  Future<void> _change() async {
    if (passCtrl.text.length < 6) {
      _toast('كلمة السر ضعيفة');
      return;
    }

    setState(() => loading = true);

    try {
      await Supabase.instance.client.auth.updateUser(
        UserAttributes(password: passCtrl.text),
      );

      if (!mounted) {
        return;
      }

      _toast('تم تغيير كلمة السر ✅');
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'change_password_page.changePassword',
        error: error,
        stack: stack,
      );
      if (mounted) {
        _toast(ErrorLogger.userMessage);
      }
    } finally {
      if (mounted) {
        setState(() => loading = false);
      }
    }
  }

  void _toast(String m) {
    AppSnackBar.show(context, message: m);
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;

    return Scaffold(
      appBar: AppBar(title: const Text('تغيير كلمة السر')),
      body: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + viewInsets),
        child: Column(
          children: [
            TextField(
              controller: passCtrl,
              obscureText: true,
              onTapOutside: (_) => InputFocusGuard.dismiss(),
              decoration: const InputDecoration(hintText: 'كلمة السر الجديدة'),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: loading ? null : _change,
                child: loading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text('تغيير'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
