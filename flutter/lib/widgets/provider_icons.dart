import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// The logo shown for a provider (CLI) in the model selector and settings.
///
/// The bundled assets under `assets/providers/` are the official brand marks
/// downloaded from each vendor (Devin ships a light variant for dark themes).
/// Unknown providers fall back to a generic icon so new providers render
/// without a code change.
class ProviderIcon extends StatelessWidget {
  final String providerId;
  final double size;

  /// Tints the monochrome marks and the fallback icon. Full-color logos
  /// (Devin, OpenCode) ignore it and always render in their brand colors.
  final Color? color;

  /// Optional accessibility label for the icon. Not visible.
  final String? semanticLabel;

  const ProviderIcon({
    super.key,
    required this.providerId,
    this.size = 18,
    this.color,
    this.semanticLabel,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveColor = color ?? Theme.of(context).colorScheme.onSurface;
    final logo = switch (providerId) {
      'devin-cli' => Image.asset(
          Theme.of(context).brightness == Brightness.dark
              ? 'assets/providers/devin_light.png'
              : 'assets/providers/devin.png',
          width: size,
          height: size,
        ),
      'opencode' => ClipRRect(
          borderRadius: BorderRadius.circular(size * 0.22),
          child: SvgPicture.asset(
            'assets/providers/opencode.svg',
            width: size,
            height: size,
          ),
        ),
      'codex' => SvgPicture.asset(
          'assets/providers/codex.svg',
          width: size,
          height: size,
          colorFilter: ColorFilter.mode(effectiveColor, BlendMode.srcIn),
        ),
      _ => Icon(
          Icons.smart_toy_outlined,
          size: size,
          color: effectiveColor,
        ),
    };

    return semanticLabel == null
        ? logo
        : Semantics(
            label: semanticLabel,
            child: logo,
          );
  }
}

/// The human-readable provider name for a known provider id. Unknown ids
/// fall back to the id itself so callers always have a non-empty label.
String providerName(String providerId) => switch (providerId) {
  'devin-cli' => 'Devin CLI',
  'opencode' => 'OpenCode',
  'codex' => 'Codex CLI',
  _ => providerId,
};
