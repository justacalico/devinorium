import 'package:flutter/material.dart';

import 'semantic_colors.dart';

/// A color-only theme.
///
/// [colors] maps kebab-case token names to [Color] values.
@immutable
class ColorTheme {
  final Map<String, Color> colors;

  const ColorTheme({required this.colors});

  static const _defaultSeed = Color(0xFF6750A4);

  Color? operator [](String token) => colors[token];

  /// Builds a [ColorScheme] from the theme colors.
  ///
  /// Missing colors are derived from the theme's `primary` color (or the
  /// default seed) using [ColorScheme.fromSeed]. Explicit colors always win.
  ColorScheme toColorScheme(Brightness brightness) {
    final seed = colors['primary'] ?? _defaultSeed;
    final base = ColorScheme.fromSeed(seedColor: seed, brightness: brightness);

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

  SemanticColors toSemanticColors(Brightness brightness) =>
      SemanticColors.fromColors(colors, brightness);

  ThemeData toThemeData(Brightness brightness) {
    final scheme = toColorScheme(brightness);
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      brightness: brightness,
      extensions: <ThemeExtension<dynamic>>[toSemanticColors(brightness)],
    );
  }
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
      default:
        return const SystemThemeChoice();
    }
  }

  String get type;

  Map<String, dynamic> toJson();
}

class SystemThemeChoice extends ThemeChoice {
  const SystemThemeChoice();

  @override
  String get type => 'system';

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
  Map<String, dynamic> toJson() => {'type': type, 'id': id};

  @override
  bool operator ==(Object other) =>
      other is BuiltInThemeChoice && other.id == id;

  @override
  int get hashCode => Object.hash(type, id);
}
