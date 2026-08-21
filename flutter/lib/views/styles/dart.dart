import 'package:flutter/material.dart';

import 'generic.dart';
import 'palette.dart';

const keywords = <String>{
  'abstract', 'as', 'assert', 'async', 'await', 'break', 'case', 'catch',
  'class', 'const', 'continue', 'default', 'deferred', 'do', 'dynamic',
  'else', 'enum', 'export', 'extends', 'extension', 'external', 'factory',
  'false', 'final', 'finally', 'for', 'Function', 'get', 'hide', 'if',
  'implements', 'import', 'in', 'interface', 'is', 'library', 'mixin',
  'new', 'null', 'on', 'operator', 'part', 'rethrow', 'return', 'set',
  'show', 'static', 'super', 'switch', 'sync', 'this', 'throw', 'true',
  'try', 'typedef', 'var', 'void', 'while', 'with', 'yield',
};

const types = <String>{
  'int', 'double', 'String', 'bool', 'List', 'Map', 'Set', 'Object',
  'num', 'Future', 'Stream', 'Iterable', 'Duration', 'DateTime',
};

TextSpan highlightDart(String code, HighlightPalette palette) =>
    highlightGeneric(code, palette, keywords: keywords, types: types);
