import 'package:flutter/material.dart';

import '../../../core/localization/app_localizations.dart';

class AppLogo extends StatelessWidget {
  const AppLogo({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const Icon(
          Icons.delivery_dining,
          size: 70,
          color: Colors.orange,
        ),
        const SizedBox(height: 10),
        Text(
          context.tr('app.name'),
          style: const TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.bold,
            color: Colors.orange,
            letterSpacing: 1.2,
          ),
        ),
      ],
    );
  }
}
