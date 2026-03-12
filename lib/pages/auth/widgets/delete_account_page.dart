import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/services/error_logger.dart';
import '../../../services/session_manager.dart';

class DeleteAccountPage extends StatelessWidget {
  const DeleteAccountPage({super.key});

  Future<void> _delete(BuildContext context) async {
    final supabase = Supabase.instance.client;
    final session = await SessionManager.instance.ensureValidSession(
      requireSession: true,
    );
    final user = session?.user;
    if (user == null) return;

    try {
      final deleted = await SessionManager.instance.runWithValidSession<bool>(
        () async {
          await supabase.from('customers').delete().eq('id', user.id);
          return true;
        },
        requireSession: true,
      );
      if (deleted != true) {
        return;
      }

      await supabase.auth.signOut();
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'delete_account_page.deleteAccount',
        error: error,
        stack: stack,
      );
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text(ErrorLogger.userMessage)),
      );
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('حذف الحساب')),
      body: Center(
        child: ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
          onPressed: () => _delete(context),
          child: const Text('حذف نهائي'),
        ),
      ),
    );
  }
}
