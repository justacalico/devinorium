part of '../thread_page.dart';

/// Custom builder for `pre` elements that renders a [CodeBlock] with
/// syntax highlighting, language label, and copy button.
class _PreBuilder extends MarkdownElementBuilder {
  final SyntaxHighlighter highlighter;

  _PreBuilder({required this.highlighter});

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
