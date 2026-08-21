import 'package:flutter/material.dart';

import 'styles/bash.dart';
import 'styles/css.dart';
import 'styles/dart.dart';
import 'styles/html.dart';
import 'styles/js.dart';
import 'styles/json.dart';
import 'styles/palette.dart';
import 'styles/python.dart';
import 'styles/rust.dart';
import 'styles/sql.dart';
import 'styles/yaml.dart';

/// Lightweight regex-based syntax highlighter for common languages.
///
/// Produces a [TextSpan] tree with colorized tokens for keywords, strings,
/// comments, numbers, and punctuation. Per-language logic lives in
/// `styles/` — this class just dispatches.
class SyntaxHighlighter {
  final HighlightPalette _palette;

  SyntaxHighlighter(ThemeData theme)
      : _palette = HighlightPalette.fromTheme(theme);

  /// Highlight [code] for the given [language]. Falls back to plain
  /// monospace text for unsupported languages.
  TextSpan highlight(String code, String language) {
    final lang = language.toLowerCase().trim();
    return switch (lang) {
      'json' => highlightJson(code, _palette),
      'dart' => highlightDart(code, _palette),
      'rust' => highlightRust(code, _palette),
      'python' || 'py' => highlightPython(code, _palette),
      'javascript' || 'js' || 'typescript' || 'ts' => highlightJs(code, _palette),
      'bash' || 'sh' || 'shell' || 'zsh' => highlightBash(code, _palette),
      'yaml' || 'yml' => highlightYaml(code, _palette),
      'sql' => highlightSql(code, _palette),
      'html' || 'xml' => highlightHtml(code, _palette),
      'css' => highlightCss(code, _palette),
      _ => TextSpan(
          text: code,
          style: TextStyle(color: _palette.base, fontFamily: 'monospace'),
        ),
    };
  }
}
