import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Maps a project type string to an icon and color for the sidebar.
class ProjectIcon {
  final IconData icon;
  final Color color;

  const ProjectIcon(this.icon, this.color);
}

/// Returns an icon + color for the given project type.
///
/// The type is detected by the backend from marker files (pubspec.yaml,
/// Cargo.toml, etc.) and stored in the database. It is only used as the
/// fallback when the project has no resolvable app icon file.
ProjectIcon projectIconForType(String type) {
  return switch (type) {
    'flutter' => const ProjectIcon(Icons.flutter_dash, Color(0xFF02569B)),
    'rust' => const ProjectIcon(Icons.build, Color(0xFFCE422B)),
    'node' => const ProjectIcon(Icons.javascript, Color(0xFF339933)),
    'python' => const ProjectIcon(Icons.code, Color(0xFF3776AB)),
    'go' => const ProjectIcon(Icons.rocket_launch, Color(0xFF00ADD8)),
    'java' => const ProjectIcon(Icons.coffee, Color(0xFFED8B00)),
    'dotnet' => const ProjectIcon(Icons.integration_instructions, Color(0xFF512BD4)),
    'ruby' => const ProjectIcon(Icons.diamond, Color(0xFFCC342D)),
    'php' => const ProjectIcon(Icons.terminal, Color(0xFF777BB4)),
    'elixir' => const ProjectIcon(Icons.water_drop, Color(0xFF4B275F)),
    'swift' => const ProjectIcon(Icons.extension, Color(0xFFF05138)),
    _ => const ProjectIcon(Icons.folder_outlined, Color(0xFF607D8B)),
  };
}

/// The project's app icon bytes as returned by `GET /api/projects/:id/icon`.
/// SVG sources render through flutter_svg; everything else goes through the
/// image codec. Undecodable content shows [fallback].
class ProjectIconImage extends StatelessWidget {
  final ({String mime, Uint8List bytes}) icon;
  final Widget fallback;
  final double size;

  const ProjectIconImage({
    super.key,
    required this.icon,
    required this.fallback,
    this.size = 30,
  });

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(6);
    if (icon.mime == 'image/svg+xml') {
      return ClipRRect(
        borderRadius: radius,
        child: SizedBox(
          width: size,
          height: size,
          child: SvgPicture.memory(
            icon.bytes,
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) => fallback,
          ),
        ),
      );
    }
    // Decode at the display size so a multi-megabyte source image does not
    // end up as a full-resolution texture for a 30px slot.
    final px = (size * MediaQuery.devicePixelRatioOf(context)).round();
    return ClipRRect(
      borderRadius: radius,
      child: Image.memory(
        icon.bytes,
        width: size,
        height: size,
        fit: BoxFit.cover,
        cacheWidth: px,
        cacheHeight: px,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => fallback,
      ),
    );
  }
}
