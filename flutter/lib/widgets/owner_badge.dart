import 'package:flutter/material.dart';

/// A small yellow badge that marks owner-only settings.
class OwnerBadge extends StatelessWidget {
  const OwnerBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFFFFC107),
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Text(
        'Owner',
        style: TextStyle(
          color: Colors.black,
          fontSize: 12,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}
