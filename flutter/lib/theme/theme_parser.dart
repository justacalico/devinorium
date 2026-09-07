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
/// rejected so users can only change theme colors.
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
    'success',
    'on-success',
    'success-container',
    'on-success-container',
    'warning',
    'on-warning',
    'warning-container',
    'on-warning-container',
    'info',
    'on-info',
    'info-container',
    'on-info-container',
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

  static final _comment = RegExp(r'/\*[\s\S]*?\*/');
  static final _metadataLinePrefix = RegExp(r'^\*+\s*');
  static final _trailingSemicolons = RegExp(r';+$');

  /// Parses [css] and returns a [ColorTheme].
  static ColorTheme parse(String css, {String? name}) {
    final lines = css.split('\n');
    final metadata = _parseMetadata(lines);

    final unclosed = _findUnclosedComment(css);
    if (unclosed != null) {
      final line = css.substring(0, unclosed).split('\n').length;
      throw ThemeParseException('unclosed comment block', line: line);
    }

    final stripped = css.replaceAll(_comment, '').trim();
    final rootBlock = _extractRootBlock(stripped);
    final colors = _parseRootBlock(rootBlock);

    final resolvedName = name?.trim();
    return ColorTheme(
      colors: colors,
      metadata: metadata,
      name: resolvedName?.isNotEmpty == true ? resolvedName : null,
    );
  }

  static ThemeMetadata _parseMetadata(List<String> lines) {
    final buffer = StringBuffer();
    var inBlock = false;
    var blockStart = 0;

    for (var index = 0; index < lines.length; index++) {
      final line = lines[index];
      final trimmed = line.trim();
      if (trimmed.startsWith('/* @theme')) {
        inBlock = true;
        blockStart = index;
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

    if (inBlock) {
      throw ThemeParseException(
        'unclosed @theme metadata block',
        line: blockStart + 1,
      );
    }

    final raw = buffer.toString().trim();
    if (raw.isEmpty) return const ThemeMetadata();

    final fields = <String, String>{};
    for (final line in raw.split('\n')) {
      final clean = line.replaceFirst(_metadataLinePrefix, '').trim();
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
    if (css.contains('@')) {
      throw const ThemeParseException('at-rules are not allowed');
    }

    final root = css.indexOf(':root');
    if (root == -1) {
      throw const ThemeParseException('missing :root block');
    }

    final before = css.substring(0, root).trim();
    if (before.isNotEmpty) {
      throw const ThemeParseException(
        'only a single :root block is allowed; remove selectors before it',
      );
    }

    final open = css.indexOf('{', root);
    if (open == -1) {
      throw const ThemeParseException(
        ':root block is missing an opening brace',
      );
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

    final after = css.substring(close).trim();
    if (after.isNotEmpty) {
      throw const ThemeParseException(
        'only a single :root block is allowed; remove trailing content',
      );
    }

    return css.substring(open + 1, close - 1);
  }

  static Map<String, Color> _parseRootBlock(String block) {
    final colors = <String, Color>{};
    final declarations = _splitDeclarations(block);

    for (final decl in declarations) {
      if (decl.contains('{') || decl.contains('}')) {
        throw const ThemeParseException(
          'nested selectors or braces are not allowed inside :root',
        );
      }

      final colon = decl.indexOf(':');
      if (colon == -1) {
        throw ThemeParseException('invalid declaration in :root: "$decl"');
      }

      final name = decl.substring(0, colon).trim();
      var value = decl.substring(colon + 1).trim();
      value = value.replaceAll(_trailingSemicolons, '');

      if (name.isEmpty) {
        throw ThemeParseException('missing property name in :root: "$decl"');
      }

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
        throw ThemeParseException('unknown theme color token "$token"');
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

    for (var i = 0; i < block.length; i++) {
      final c = block[i];
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

  static int? _findUnclosedComment(String css) {
    var inComment = false;
    var start = 0;
    for (var i = 0; i < css.length - 1; i++) {
      if (!inComment) {
        if (css[i] == '/' && css[i + 1] == '*') {
          inComment = true;
          start = i;
          i++;
        }
      } else {
        if (css[i] == '*' && css[i + 1] == '/') {
          inComment = false;
          i++;
        }
      }
    }
    return inComment ? start : null;
  }
}
