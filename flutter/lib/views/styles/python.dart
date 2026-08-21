import 'package:flutter/material.dart';

import 'generic.dart';
import 'palette.dart';

const keywords = <String>{
  'False', 'None', 'True', 'and', 'as', 'assert', 'async', 'await',
  'break', 'class', 'continue', 'def', 'del', 'elif', 'else', 'except',
  'finally', 'for', 'from', 'global', 'if', 'import', 'in', 'is',
  'lambda', 'nonlocal', 'not', 'or', 'pass', 'raise', 'return', 'try',
  'while', 'with', 'yield',
};

const types = <String>{
  'int', 'float', 'str', 'bool', 'list', 'dict', 'set', 'tuple',
  'bytes', 'object', 'type', 'complex',
};

TextSpan highlightPython(String code, HighlightPalette palette) =>
    highlightGeneric(code, palette, keywords: keywords, types: types);
