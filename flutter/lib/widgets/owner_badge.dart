import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../theme/semantic_colors.dart';

/// A small badge that marks owner-only settings.
class OwnerBadge extends StatelessWidget {
  const OwnerBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final semantic = SemanticColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: semantic.warning,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        l10n(context).ownerBadge,
        style: TextStyle(
          color: semantic.onWarning,
          fontSize: 12,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}
