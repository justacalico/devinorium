import 'package:flutter/material.dart';

import 'theme_model.dart';

/// Thrown when a theme file contains anything other than color definitions.
class ThemeParseException implements Exception {
  final String message;
  final int? line;

  const ThemeParseException(this.message, {this.line});

  @override
  String toString() {
    if (line != null) return 'ThemeParseException at line $line: $message';
    return 'ThemeParseException: $message';
  }
}

/// Parses a restricted CSS-like format into a [ColorTheme].
///
/// Only these constructs are allowed:
///   * a leading `/* @theme ... */` block holding `version`, `creator`, and
///     `description` metadata
///   * a single `:root { ... }` block
///   * custom properties (`--name`) whose values are hex colors
///
/// Any standard selector, at-rule, layout property, or non-color value is
/// rejected so users can only change theme colours.
class ThemeParser {
  ThemeParser._();

  static final _hexColor = RegExp(r'^#([0-9a-fA-F]{6}|[0-9a-fA-F]{8})$');

  static final _allowedTokens = {
    'primary',
    'on-primary',
    'primary-container',
    'on-primary-container',
    'secondary',
    'on-secondary',
    'secondary-container',
    'on-secondary-container',
    'tertiary',
    'on-tertiary',
    'tertiary-container',
    'on-tertiary-container',
    'error',
    'on-error',
    'error-container',
    'on-error-container',
    'surface',
    'on-surface',
    'on-surface-variant',
    'surface-dim',
    'surface-bright',
    'surface-container-lowest',
    'surface-container-low',
    'surface-container',
    'surface-container-high',
    'surface-container-highest',
    'outline',
    'outline-variant',
    'shadow',
    'scrim',
    'inverse-surface',
    'on-inverse-surface',
    'inverse-primary',
    'surface-tint',
  };

  static final _forbiddenProperties = {
    'display',
    'position',
    'top',
    'left',
    'right',
    'bottom',
    'width',
    'height',
    'min-width',
    'min-height',
    'max-width',
    'max-height',
    'margin',
    'margin-top',
    'margin-left',
    'margin-right',
    'margin-bottom',
    'padding',
    'padding-top',
    'padding-left',
    'padding-right',
    'padding-bottom',
    'border',
    'border-radius',
    'transform',
    'animation',
    'transition',
    'z-index',
    'flex',
    'grid',
    'float',
    'font',
    'font-size',
    'font-family',
    'font-weight',
    'line-height',
    'text-align',
    'cursor',
  };

  /// Parses [css] and returns a [ColorTheme].
  static ColorTheme parse(String css, {String? name}) {
    final lines = css.split('\n');
    final metadata = _parseMetadata(lines);
    final rootBlock = _extractRootBlock(css);
    final colors = _parseRootBlock(rootBlock, lines);

    return ColorTheme(
      colors: colors,
      metadata: metadata,
      name: name,
    );
  }

  static ThemeMetadata _parseMetadata(List<String> lines) {
    final buffer = StringBuffer();
    var inBlock = false;

    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.startsWith('/* @theme')) {
        inBlock = true;
        buffer.clear();
        final rest = trimmed.substring('/* @theme'.length);
        if (rest.contains('*/')) {
          buffer.writeln(rest.substring(0, rest.indexOf('*/')));
          inBlock = false;
          break;
        } else {
          buffer.writeln(rest.trim());
        }
      } else if (inBlock) {
        if (trimmed.contains('*/')) {
          final end = trimmed.indexOf('*/');
          buffer.writeln(trimmed.substring(0, end).trim());
          inBlock = false;
          break;
        } else {
          buffer.writeln(trimmed);
        }
      }
    }

    final raw = buffer.toString().trim();
    if (raw.isEmpty) return const ThemeMetadata();

    final fields = <String, String>{};
    for (final line in raw.split('\n')) {
      final clean = line.replaceFirst(RegExp(r'^\*+\s*'), '').trim();
      if (clean.isEmpty) continue;
      final colon = clean.indexOf(':');
      if (colon == -1) continue;
      final key = clean.substring(0, colon).trim().toLowerCase();
      final value = clean.substring(colon + 1).trim();
      fields[key] = value;
    }

    return ThemeMetadata(
      version: fields['version'] ?? '1.0.0',
      creator: fields['creator'] ?? '',
      description: fields['description'] ?? '',
    );
  }

  static String _extractRootBlock(String css) {
    final root = css.indexOf(':root');
    if (root == -1) {
      throw const ThemeParseException('missing :root block');
    }

    final open = css.indexOf('{', root);
    if (open == -1) {
      throw const ThemeParseException(':root block is missing an opening brace');
    }

    var depth = 1;
    var close = open + 1;
    while (depth > 0 && close < css.length) {
      final char = css[close];
      if (char == '{') depth++;
      if (char == '}') depth--;
      close++;
    }

    if (depth != 0) {
      throw const ThemeParseException(':root block is missing a closing brace');
    }

    return css.substring(open + 1, close - 1);
  }

  static Map<String, Color> _parseRootBlock(String block, List<String> lines) {
    final colors = <String, Color>{};
    final declarations = _splitDeclarations(block);

    for (final decl in declarations) {
      final colon = decl.indexOf(':');
      if (colon == -1) continue;

      final name = decl.substring(0, colon).trim();
      final value = decl.substring(colon + 1).trim().replaceFirst(';', '');

      if (name.isEmpty) continue;

      if (!name.startsWith('--')) {
        throw ThemeParseException(
          'only custom properties are allowed inside :root; found "$name"',
        );
      }

      final token = name.substring(2);

      if (_forbiddenProperties.contains(token)) {
        throw ThemeParseException(
          'layout or typography properties are not allowed: "$name"',
        );
      }

      if (!_allowedTokens.contains(token)) {
        throw ThemeParseException(
          'unknown theme color token "$token"',
        );
      }

      final color = _parseColor(value);
      if (color == null) {
        throw ThemeParseException(
          'value for "$token" must be a hex color, got "$value"',
        );
      }

      colors[token] = color;
    }

    return colors;
  }

  static List<String> _splitDeclarations(String block) {
    final result = <String>[];
    final buffer = StringBuffer();
    var inComment = false;

    for (var i = 0; i < block.length; i++) {
      final c = block[i];
      final next = i + 1 < block.length ? block[i + 1] : '';

      if (c == '/' && next == '*') {
        inComment = true;
        i++;
        continue;
      }
      if (c == '*' && next == '/') {
        inComment = false;
        i++;
        continue;
      }
      if (inComment) continue;

      if (c == ';') {
        result.add(buffer.toString().trim());
        buffer.clear();
      } else {
        buffer.write(c);
      }
    }

    final tail = buffer.toString().trim();
    if (tail.isNotEmpty) result.add(tail);

    return result.where((d) => d.isNotEmpty).toList();
  }

  static Color? _parseColor(String value) {
    final trimmed = value.trim();
    if (!_hexColor.hasMatch(trimmed)) return null;
    final hex = trimmed.substring(1);
    if (hex.length == 6) {
      final r = int.parse(hex.substring(0, 2), radix: 16);
      final g = int.parse(hex.substring(2, 4), radix: 16);
      final b = int.parse(hex.substring(4, 6), radix: 16);
      return Color.fromARGB(255, r, g, b);
    }
    if (hex.length == 8) {
      final a = int.parse(hex.substring(0, 2), radix: 16);
      final r = int.parse(hex.substring(2, 4), radix: 16);
      final g = int.parse(hex.substring(4, 6), radix: 16);
      final b = int.parse(hex.substring(6, 8), radix: 16);
      return Color.fromARGB(a, r, g, b);
    }
    return null;
  }
}
