import 'package:flutter/material.dart';

/// Lightweight regex-based syntax highlighter for common languages.
///
/// Produces a [TextSpan] tree with colorized tokens for keywords, strings,
/// comments, numbers, and punctuation. Supports a subset of languages that
/// are most likely to appear in AI-generated code blocks.
class SyntaxHighlighter {
  final Color _keyword;
  final Color _string;
  final Color _comment;
  final Color _number;
  final Color _type;
  final Color _function;
  final Color _variable;
  final Color _base;

  SyntaxHighlighter(ThemeData theme)
      : _keyword = theme.colorScheme.primary,
        _string = const Color(0xFF4CAF50),
        _comment = theme.colorScheme.onSurfaceVariant.withAlpha(153),
        _number = const Color(0xFFFF9800),
        _type = const Color(0xFFE91E63),
        _function = const Color(0xFF2196F3),
        _variable = const Color(0xFF9C27B0),
        _base = theme.colorScheme.onSurface;

  /// Highlight [code] for the given [language]. Falls back to plain
  /// monospace text for unsupported languages.
  TextSpan highlight(String code, String language) {
    final lang = language.toLowerCase().trim();
    return switch (lang) {
      'json' => _highlightJson(code),
      'dart' => _highlightDart(code),
      'rust' => _highlightRust(code),
      'python' || 'py' => _highlightPython(code),
      'javascript' || 'js' || 'typescript' || 'ts' => _highlightJs(code),
      'bash' || 'sh' || 'shell' || 'zsh' => _highlightBash(code),
      'yaml' || 'yml' => _highlightYaml(code),
      'sql' => _highlightSql(code),
      'html' || 'xml' => _highlightHtml(code),
      'css' => _highlightCss(code),
      _ => TextSpan(text: code, style: TextStyle(color: _base, fontFamily: 'monospace')),
    };
  }

  TextSpan _span(String text, Color color, {FontStyle? style, FontWeight? weight}) {
    return TextSpan(
      text: text,
      style: TextStyle(color: color, fontFamily: 'monospace', fontStyle: style, fontWeight: weight),
    );
  }

  TextSpan _highlightJson(String code) {
    final spans = <TextSpan>[];
    final regex = RegExp(
      r'"(?:[^"\\]|\\.)*"\s*:|"(?:[^"\\]|\\.)*"|\b(?:true|false|null)\b|-?\d+\.?\d*([eE][+-]?\d+)?|[{}\[\],:]',
    );
    _tokenize(code, regex, spans, (match) {
      final t = match[0]!;
      if (t.endsWith(':')) {
        return _span(t, _keyword);
      } else if (t.startsWith('"')) {
        return _span(t, _string);
      } else if (t == 'true' || t == 'false' || t == 'null') {
        return _span(t, _number);
      } else if (RegExp(r'^-?\d').hasMatch(t)) {
        return _span(t, _number);
      } else if (RegExp(r'^[{}\[\],:]$').hasMatch(t)) {
        return _span(t, _variable);
      }
      return _span(t, _base);
    });
    return TextSpan(children: spans);
  }

  TextSpan _highlightDart(String code) {
    return _highlightGeneric(code, keywords: _dartKeywords, types: _dartTypes);
  }

  TextSpan _highlightRust(String code) {
    return _highlightGeneric(code, keywords: _rustKeywords, types: _rustTypes);
  }

  TextSpan _highlightPython(String code) {
    return _highlightGeneric(code, keywords: _pythonKeywords, types: _pythonTypes);
  }

  TextSpan _highlightJs(String code) {
    return _highlightGeneric(code, keywords: _jsKeywords, types: _jsTypes);
  }

  TextSpan _highlightBash(String code) {
    final spans = <TextSpan>[];
    final regex = RegExp(
        r'#[^\n]*|"(?:[^"\\]|\\.)*"|' r"'(?:[^'\\]|\\.)*'" r'|\$\w+|\b(?:if|then|else|fi|for|while|do|done|case|esac|function|return|export|echo|cd|ls|mkdir|rm|cp|mv|cat|sudo|apt|brew|npm|cargo|flutter|dart|git)\b');
    _tokenize(code, regex, spans, (match) {
      final t = match[0]!;
      if (t.startsWith('#')) return _span(t, _comment, style: FontStyle.italic);
      if (t.startsWith('"') || t.startsWith("'")) return _span(t, _string);
      if (t.startsWith(r'$')) return _span(t, _variable);
      return _span(t, _keyword);
    });
    return TextSpan(children: spans);
  }

  TextSpan _highlightYaml(String code) {
    final spans = <TextSpan>[];
    final regex = RegExp(
        r'#.*|^\s*[\w-]+:|"(?:[^"\\]|\\.)*"|' r"'(?:[^'\\]|\\.)*'" r'|\b\d+\b|[-:]');
    _tokenize(code, regex, spans, (match) {
      final t = match[0]!;
      if (t.startsWith('#')) return _span(t, _comment, style: FontStyle.italic);
      if (t.endsWith(':') && !t.startsWith('"')) return _span(t, _keyword);
      if (t.startsWith('"') || t.startsWith("'")) return _span(t, _string);
      if (RegExp(r'^\d+$').hasMatch(t)) return _span(t, _number);
      return _span(t, _base);
    });
    return TextSpan(children: spans);
  }

  TextSpan _highlightSql(String code) {
    return _highlightGeneric(code, keywords: _sqlKeywords, types: {});
  }

  TextSpan _highlightHtml(String code) {
    final spans = <TextSpan>[];
    final regex = RegExp(r'<!--[\s\S]*?-->|<\/?\w+[^>]*>|[^<]+');
    _tokenize(code, regex, spans, (match) {
      final t = match[0]!;
      if (t.startsWith('<!--')) return _span(t, _comment, style: FontStyle.italic);
      if (t.startsWith('<')) {
        final tagRegex = RegExp(r'<\/?(\w+)|(\w+)=|("[^"]*")|(' r"'[^']*'" r')|>');
        final tagSpans = <TextSpan>[];
        _tokenize(t, tagRegex, tagSpans, (m) {
          final mt = m[0]!;
          if (mt.startsWith('</') || mt.startsWith('<')) return _span(mt, _keyword);
          if (mt.endsWith('=')) return _span(mt, _variable);
          if (mt.startsWith('"') || mt.startsWith("'")) return _span(mt, _string);
          if (mt == '>') return _span(mt, _keyword);
          return _span(mt, _function);
        });
        return TextSpan(children: tagSpans);
      }
      return _span(t, _base);
    });
    return TextSpan(children: spans);
  }

  TextSpan _highlightCss(String code) {
    final spans = <TextSpan>[];
    final regex = RegExp(
        r'/\*[\s\S]*?\*/|[\w-]+\s*:|#[\w-]+|\.[\w-]+|"[^"]*"|' r"'[^']*'" r'|\b\d+\.?\d*(px|em|rem|%|vh|vw|s|ms)?\b|[{};:]');
    _tokenize(code, regex, spans, (match) {
      final t = match[0]!;
      if (t.startsWith('/*')) return _span(t, _comment, style: FontStyle.italic);
      if (t.endsWith(':') && !t.startsWith('"')) return _span(t, _keyword);
      if (t.startsWith('#')) return _span(t, _type);
      if (t.startsWith('.')) return _span(t, _function);
      if (t.startsWith('"') || t.startsWith("'")) return _span(t, _string);
      if (RegExp(r'^\d').hasMatch(t)) return _span(t, _number);
      if (RegExp(r'^[{};:]$').hasMatch(t)) return _span(t, _variable);
      return _span(t, _base);
    });
    return TextSpan(children: spans);
  }

  TextSpan _highlightGeneric(String code, {required Set<String> keywords, required Set<String> types}) {
    final spans = <TextSpan>[];
    final regex = RegExp(
      r'//[^\n]*|#[^\n]*|/\*[\s\S]*?\*/|"(?:[^"\\]|\\.)*"|'
          r"'(?:[^'\\]|\\.)*'"
          r'|`(?:[^`\\]|\\.)*`|\b\d+\.?\d*\b|\b[A-Z]\w*\b|\b\w+\b|[^\s\w]',
    );
    _tokenize(code, regex, spans, (match) {
      final t = match[0]!;
      if (t.startsWith('//') || t.startsWith('#') || t.startsWith('/*')) {
        return _span(t, _comment, style: FontStyle.italic);
      }
      if (t.startsWith('"') || t.startsWith("'") || t.startsWith('`')) {
        return _span(t, _string);
      }
      if (RegExp(r'^\d').hasMatch(t)) {
        return _span(t, _number);
      }
      if (keywords.contains(t)) {
        return _span(t, _keyword, weight: FontWeight.w600);
      }
      if (types.contains(t)) {
        return _span(t, _type);
      }
      if (RegExp(r'^[A-Z]').hasMatch(t)) {
        return _span(t, _type);
      }
      return _span(t, _base);
    });
    return TextSpan(children: spans);
  }

  void _tokenize(String code, RegExp regex, List<TextSpan> spans, TextSpan Function(Match) onMatch) {
    var lastEnd = 0;
    for (final match in regex.allMatches(code)) {
      if (match.start > lastEnd) {
        spans.add(_span(code.substring(lastEnd, match.start), _base));
      }
      spans.add(onMatch(match));
      lastEnd = match.end;
    }
    if (lastEnd < code.length) {
      spans.add(_span(code.substring(lastEnd), _base));
    }
  }

  static const _dartKeywords = {
    'abstract', 'as', 'assert', 'async', 'await', 'break', 'case', 'catch',
    'class', 'const', 'continue', 'default', 'deferred', 'do', 'dynamic',
    'else', 'enum', 'export', 'extends', 'extension', 'external', 'factory',
    'false', 'final', 'finally', 'for', 'Function', 'get', 'hide', 'if',
    'implements', 'import', 'in', 'interface', 'is', 'library', 'mixin',
    'new', 'null', 'on', 'operator', 'part', 'rethrow', 'return', 'set',
    'show', 'static', 'super', 'switch', 'sync', 'this', 'throw', 'true',
    'try', 'typedef', 'var', 'void', 'while', 'with', 'yield',
  };

  static const _dartTypes = {
    'int', 'double', 'String', 'bool', 'List', 'Map', 'Set', 'Object',
    'num', 'Future', 'Stream', 'Iterable', 'Duration', 'DateTime',
  };

  static const _rustKeywords = {
    'as', 'async', 'await', 'break', 'const', 'continue', 'crate', 'dyn',
    'else', 'enum', 'extern', 'false', 'fn', 'for', 'if', 'impl', 'in',
    'let', 'loop', 'match', 'mod', 'move', 'mut', 'pub', 'ref', 'return',
    'self', 'Self', 'static', 'struct', 'super', 'trait', 'true', 'type',
    'unsafe', 'use', 'where', 'while', 'yield',
  };

  static const _rustTypes = {
    'i8', 'i16', 'i32', 'i64', 'i128', 'isize', 'u8', 'u16', 'u32', 'u64',
    'u128', 'usize', 'f32', 'f64', 'bool', 'char', 'str', 'String', 'Vec',
    'Option', 'Result', 'Box', 'Rc', 'Arc',
  };

  static const _pythonKeywords = {
    'False', 'None', 'True', 'and', 'as', 'assert', 'async', 'await',
    'break', 'class', 'continue', 'def', 'del', 'elif', 'else', 'except',
    'finally', 'for', 'from', 'global', 'if', 'import', 'in', 'is',
    'lambda', 'nonlocal', 'not', 'or', 'pass', 'raise', 'return', 'try',
    'while', 'with', 'yield',
  };

  static const _pythonTypes = {
    'int', 'float', 'str', 'bool', 'list', 'dict', 'set', 'tuple',
    'bytes', 'object', 'type', 'complex',
  };

  static const _jsKeywords = {
    'break', 'case', 'catch', 'class', 'const', 'continue', 'debugger',
    'default', 'delete', 'do', 'else', 'export', 'extends', 'false',
    'finally', 'for', 'function', 'if', 'import', 'in', 'instanceof',
    'new', 'null', 'return', 'super', 'switch', 'this', 'throw', 'true',
    'try', 'typeof', 'var', 'void', 'while', 'with', 'yield', 'let',
    'static', 'async', 'await', 'of',
  };

  static const _jsTypes = {
    'Array', 'Object', 'String', 'Number', 'Boolean', 'Promise', 'Map',
    'Set', 'Symbol', 'BigInt', 'Date', 'RegExp', 'Error',
  };

  static const _sqlKeywords = {
    'SELECT', 'FROM', 'WHERE', 'INSERT', 'UPDATE', 'DELETE', 'CREATE',
    'TABLE', 'DROP', 'ALTER', 'INDEX', 'VIEW', 'JOIN', 'LEFT', 'RIGHT',
    'INNER', 'OUTER', 'ON', 'AS', 'AND', 'OR', 'NOT', 'NULL', 'IS',
    'IN', 'EXISTS', 'GROUP', 'BY', 'ORDER', 'HAVING', 'LIMIT', 'OFFSET',
    'DISTINCT', 'UNION', 'ALL', 'CASE', 'WHEN', 'THEN', 'ELSE', 'END',
    'BEGIN', 'COMMIT', 'ROLLBACK', 'PRIMARY', 'KEY', 'FOREIGN',
    'REFERENCES', 'DEFAULT', 'UNIQUE', 'CONSTRAINT', 'CHECK',
    'select', 'from', 'where', 'insert', 'update', 'delete', 'create',
    'table', 'drop', 'alter', 'index', 'view', 'join', 'left', 'right',
    'inner', 'outer', 'on', 'as', 'and', 'or', 'not', 'null', 'is',
    'in', 'exists', 'group', 'by', 'order', 'having', 'limit', 'offset',
    'distinct', 'union', 'all', 'case', 'when', 'then', 'else', 'end',
    'begin', 'commit', 'rollback', 'primary', 'key', 'foreign',
    'references', 'default', 'unique', 'constraint', 'check',
  };
}
