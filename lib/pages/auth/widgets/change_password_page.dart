import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/services/error_logger.dart';

class ChangePasswordPage extends StatefulWidget {
  const ChangePasswordPage({super.key});

  @override
  State<ChangePasswordPage> createState() => _ChangePasswordPageState();
}

class _ChangePasswordPageState extends State<ChangePasswordPage> {
  final passCtrl = TextEditingController();
  bool loading = false;

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
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('تغيير كلمة السر')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: passCtrl,
              obscureText: true,
              decoration: const InputDecoration(hintText: 'كلمة السر الجديدة'),
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: loading ? null : _change,
              child: loading
                  ? const CircularProgressIndicator()
                  : const Text('تغيير'),
            ),
          ],
        ),
      ),
    );
  }
}
