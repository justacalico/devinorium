import 'package:flutter/material.dart';

/// Maps a project type string to an icon and color for the sidebar.
class ProjectIcon {
  final IconData icon;
  final Color color;

  const ProjectIcon(this.icon, this.color);
}

/// Returns an icon + color for the given project type.
///
/// The type is detected by the backend from marker files (pubspec.yaml,
/// Cargo.toml, etc.) and stored in the database. Unknown types fall back
/// to a generic folder icon.
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
