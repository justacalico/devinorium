import 'package:flutter/material.dart';

import 'generic.dart';
import 'palette.dart';

const keywords = <String>{
  'abstract', 'assert', 'break', 'case', 'catch', 'class', 'const',
  'continue', 'default', 'do', 'else', 'enum', 'exports', 'extends',
  'false', 'final', 'finally', 'for', 'goto', 'if', 'implements',
  'import', 'instanceof', 'interface', 'module', 'native', 'new', 'null',
  'open', 'opens', 'package', 'permits', 'private', 'protected',
  'provides', 'public', 'record', 'requires', 'return', 'sealed',
  'static', 'strictfp', 'super', 'switch', 'synchronized', 'this',
  'throw', 'throws', 'to', 'transient', 'transitive', 'true', 'try',
  'uses', 'var', 'void', 'volatile', 'while', 'with', 'yield',
};

const types = <String>{
  'boolean', 'byte', 'char', 'double', 'float', 'int', 'long', 'short',
  'Boolean', 'Byte', 'Character', 'Double', 'Float', 'Integer', 'Long',
  'Short', 'String', 'StringBuilder', 'Object', 'Class', 'Number',
  'Exception', 'RuntimeException', 'Comparable', 'Iterable', 'Iterator',
  'Collection', 'List', 'ArrayList', 'LinkedList', 'Map', 'HashMap',
  'Set', 'HashSet', 'Queue', 'Deque', 'Optional', 'Stream', 'System',
  'Math', 'Thread', 'Void',
};

TextSpan highlightJava(String code, HighlightPalette palette) =>
    highlightGeneric(code, palette, keywords: keywords, types: types);
