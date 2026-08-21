import 'package:flutter/material.dart';

import 'generic.dart';
import 'palette.dart';

const keywords = <String>{
  'break', 'case', 'catch', 'class', 'const', 'continue', 'debugger',
  'default', 'delete', 'do', 'else', 'export', 'extends', 'false',
  'finally', 'for', 'function', 'if', 'import', 'in', 'instanceof',
  'new', 'null', 'return', 'super', 'switch', 'this', 'throw', 'true',
  'try', 'typeof', 'var', 'void', 'while', 'with', 'yield', 'let',
  'static', 'async', 'await', 'of',
};

const types = <String>{
  'Array', 'Object', 'String', 'Number', 'Boolean', 'Promise', 'Map',
  'Set', 'Symbol', 'BigInt', 'Date', 'RegExp', 'Error',
};

TextSpan highlightJs(String code, HighlightPalette palette) =>
    highlightGeneric(code, palette, keywords: keywords, types: types);
