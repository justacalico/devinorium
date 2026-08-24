import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart' hide SyntaxHighlighter;
import 'package:markdown/markdown.dart' as markdown;

import 'code_block.dart';
import 'syntax_highlighter.dart';

/// Markdown style sheet shared by the merge request and issue views.
MarkdownStyleSheet markdownStyleSheet(ThemeData theme) =>
    MarkdownStyleSheet.fromTheme(theme).copyWith(
      p: theme.textTheme.bodyLarge?.copyWith(height: 1.5),
      code: theme.textTheme.bodySmall?.copyWith(
        fontFamily: 'monospace',
        backgroundColor: theme.colorScheme.surfaceContainerHigh,
      ),
      codeblockDecoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
      ),
      codeblockPadding: const EdgeInsets.all(12),
    );

/// Markdown element builder that renders fenced code blocks with syntax
/// highlighting via [CodeBlock].
class PreBuilder extends MarkdownElementBuilder {
  final SyntaxHighlighter highlighter;

  PreBuilder({required this.highlighter});

  @override
  bool isBlockElement() => true;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    markdown.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    String code = '';
    String language = '';
    if (element.children != null && element.children!.isNotEmpty) {
      final child = element.children!.first;
      if (child is markdown.Element && child.tag == 'code') {
        final cls = child.attributes['class'] ?? '';
        if (cls.startsWith('language-')) {
          language = cls.substring('language-'.length);
        }
        for (final node in child.children ?? <markdown.Node>[]) {
          if (node is markdown.Text) {
            code += node.text;
          }
        }
      }
    }
    if (code.isEmpty) {
      for (final node in element.children ?? <markdown.Node>[]) {
        if (node is markdown.Text) {
          code += node.text;
        }
      }
    }
    return CodeBlock(code: code, language: language, highlighter: highlighter);
  }
}

/// Convert the small subset of HTML used by GitLab system notes into Markdown
/// so [MarkdownBody] can render them. Non-system notes are already Markdown.
String htmlToMarkdown(String html) {
  var text = html;

  text = decodeHtmlEntities(text);

  text = text.replaceAllMapped(RegExp(r'<br\s*/?>'), (_) => '\n');

  text = text.replaceAllMapped(
    RegExp(
      r"""<a[^>]*href=["']([^"']*)["'][^>]*>([\s\S]*?)</a>""",
      caseSensitive: false,
    ),
    (m) => '[${cleanWhitespace(m[2]!)}](${decodeHtmlEntities(m[1]!)})',
  );

  text = text.replaceAllMapped(
    RegExp(r'<li[^>]*>([\s\S]*?)</li>', caseSensitive: false),
    (m) => '- ${cleanWhitespace(m[1]!)}\n',
  );

  text = text
      .replaceAll(RegExp(r'</?ul[^>]*>', caseSensitive: false), '')
      .replaceAll(RegExp(r'</?ol[^>]*>', caseSensitive: false), '')
      .replaceAll(RegExp(r'<p[^>]*>', caseSensitive: false), '\n\n')
      .replaceAll(RegExp(r'</p>', caseSensitive: false), '')
      .replaceAll(RegExp(r'</?div[^>]*>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'</?span[^>]*>', caseSensitive: false), '')
      .replaceAll(RegExp(r'</?b[^>]*>', caseSensitive: false), '**')
      .replaceAll(RegExp(r'</?strong[^>]*>', caseSensitive: false), '**')
      .replaceAll(RegExp(r'</?i[^>]*>', caseSensitive: false), '*')
      .replaceAll(RegExp(r'</?em[^>]*>', caseSensitive: false), '*');

  text = text.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  return text;
}

String cleanWhitespace(String value) {
  return value.replaceAll(RegExp(r'\s+'), ' ').trim();
}

String decodeHtmlEntities(String text) {
  var out = text;
  out = out.replaceAll('&lt;', '<');
  out = out.replaceAll('&gt;', '>');
  out = out.replaceAll('&amp;', '&');
  out = out.replaceAll('&quot;', '"');
  out = out.replaceAll('&apos;', "'");
  out = out.replaceAll('&nbsp;', ' ');

  out = out.replaceAllMapped(
    RegExp(r'&#x([0-9a-fA-F]+);'),
    (m) => String.fromCharCode(int.parse(m[1]!, radix: 16)),
  );
  out = out.replaceAllMapped(
    RegExp(r'&#(\d+);'),
    (m) => String.fromCharCode(int.parse(m[1]!)),
  );

  return out;
}
