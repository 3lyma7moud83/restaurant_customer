import 'package:flutter/material.dart';

class AppLogo extends StatelessWidget {
  const AppLogo({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: const [
        Icon(
          Icons.delivery_dining,
          size: 70,
          color: Colors.orange,
        ),
        SizedBox(height: 10),
        Text(
          'Delivery',
          style: TextStyle(
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
