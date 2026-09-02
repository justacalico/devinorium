import 'package:flutter/material.dart';

/// Metadata parsed from a CSS-like theme file's `@theme` block.
@immutable
class ThemeMetadata {
  final String version;
  final String creator;
  final String description;

  const ThemeMetadata({
    this.version = '1.0.0',
    this.creator = '',
    this.description = '',
  });

  Map<String, dynamic> toJson() => {
        'version': version,
        'creator': creator,
        'description': description,
      };

  factory ThemeMetadata.fromJson(Map<String, dynamic> json) => ThemeMetadata(
        version: json['version'] as String? ?? '1.0.0',
        creator: json['creator'] as String? ?? '',
        description: json['description'] as String? ?? '',
      );
}

/// A parsed color-only theme.
///
/// [colors] maps kebab-case CSS custom property names (without the `--`
/// prefix) to [Color] values.
@immutable
class ColorTheme {
  final Map<String, Color> colors;
  final ThemeMetadata metadata;
  final String? name;

  const ColorTheme({
    required this.colors,
    this.metadata = const ThemeMetadata(),
    this.name,
  });

  static const _defaultSeed = Color(0xFF6750A4);

  Color? operator [](String token) => colors[token];

  /// Builds a [ColorScheme] from the parsed colors.
  ///
  /// Missing colors are derived from the theme's `primary` color (or the
  /// default seed) using [ColorScheme.fromSeed]. Explicit colors always win.
  ColorScheme toColorScheme(Brightness brightness) {
    final seed = colors['primary'] ?? _defaultSeed;
    final base = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
    );

    return base.copyWith(
      primary: colors['primary'],
      onPrimary: colors['on-primary'],
      primaryContainer: colors['primary-container'],
      onPrimaryContainer: colors['on-primary-container'],
      secondary: colors['secondary'],
      onSecondary: colors['on-secondary'],
      secondaryContainer: colors['secondary-container'],
      onSecondaryContainer: colors['on-secondary-container'],
      tertiary: colors['tertiary'],
      onTertiary: colors['on-tertiary'],
      tertiaryContainer: colors['tertiary-container'],
      onTertiaryContainer: colors['on-tertiary-container'],
      error: colors['error'],
      onError: colors['on-error'],
      errorContainer: colors['error-container'],
      onErrorContainer: colors['on-error-container'],
      surface: colors['surface'],
      onSurface: colors['on-surface'],
      onSurfaceVariant: colors['on-surface-variant'],
      surfaceDim: colors['surface-dim'],
      surfaceBright: colors['surface-bright'],
      surfaceContainerLowest: colors['surface-container-lowest'],
      surfaceContainerLow: colors['surface-container-low'],
      surfaceContainer: colors['surface-container'],
      surfaceContainerHigh: colors['surface-container-high'],
      surfaceContainerHighest: colors['surface-container-highest'],
      outline: colors['outline'],
      outlineVariant: colors['outline-variant'],
      shadow: colors['shadow'],
      scrim: colors['scrim'],
      inverseSurface: colors['inverse-surface'],
      onInverseSurface: colors['on-inverse-surface'],
      inversePrimary: colors['inverse-primary'],
      surfaceTint: colors['surface-tint'],
    );
  }

  ThemeData toThemeData(Brightness brightness) => ThemeData(
        useMaterial3: true,
        colorScheme: toColorScheme(brightness),
        brightness: brightness,
      );

  ColorTheme copyWith({
    Map<String, Color>? colors,
    ThemeMetadata? metadata,
    String? name,
  }) =>
      ColorTheme(
        colors: colors ?? this.colors,
        metadata: metadata ?? this.metadata,
        name: name ?? this.name,
      );
}

/// The user's active theme choice.
@immutable
sealed class ThemeChoice {
  const ThemeChoice();

  factory ThemeChoice.fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String?;
    switch (type) {
      case 'system':
        return const SystemThemeChoice();
      case 'builtIn':
        final id = json['id'] as String? ?? 'light';
        return BuiltInThemeChoice(id);
      case 'custom':
        final css = json['css'] as String? ?? '';
        final name = json['name'] as String?;
        return CustomThemeChoice(css, name: name);
      default:
        return const SystemThemeChoice();
    }
  }

  String get type;
  String? get builtInId;
  String? get customCss;

  Map<String, dynamic> toJson();
}

class SystemThemeChoice extends ThemeChoice {
  const SystemThemeChoice();

  @override
  String get type => 'system';

  @override
  String? get builtInId => null;

  @override
  String? get customCss => null;

  @override
  Map<String, dynamic> toJson() => {'type': type};

  @override
  bool operator ==(Object other) => other is SystemThemeChoice;

  @override
  int get hashCode => type.hashCode;
}

class BuiltInThemeChoice extends ThemeChoice {
  final String id;

  const BuiltInThemeChoice(this.id);

  @override
  String get type => 'builtIn';

  @override
  String? get builtInId => id;

  @override
  String? get customCss => null;

  @override
  Map<String, dynamic> toJson() => {'type': type, 'id': id};

  @override
  bool operator ==(Object other) =>
      other is BuiltInThemeChoice && other.id == id;

  @override
  int get hashCode => Object.hash(type, id);
}

class CustomThemeChoice extends ThemeChoice {
  final String css;
  final String? name;

  const CustomThemeChoice(this.css, {this.name});

  @override
  String get type => 'custom';

  @override
  String? get builtInId => null;

  @override
  String? get customCss => css;

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        'css': css,
        if (name != null) 'name': name,
      };

  @override
  bool operator ==(Object other) =>
      other is CustomThemeChoice && other.css == css && other.name == name;

  @override
  int get hashCode => Object.hash(type, css, name);
}
