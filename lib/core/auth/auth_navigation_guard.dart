import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../theme/app_theme.dart';
import '../ui/input_focus_guard.dart';
import '../../pages/auth/login_page.dart';

Future<bool> ensureUserAuthenticated(BuildContext context) async {
  final client = Supabase.instance.client;
  if (client.auth.currentUser != null) {
    return true;
  }

  await InputFocusGuard.prepareForUiTransition(context: context);
  if (!context.mounted) {
    return false;
  }

  await Navigator.of(context).push(
    AppTheme.platformPageRoute(builder: (_) => const LoginPage()),
  );

  if (!context.mounted) {
    return false;
  }
  return client.auth.currentUser != null;
}
