import 'package:flutter/material.dart';

import 'generic.dart';
import 'palette.dart';

const keywords = <String>{
  'as', 'async', 'await', 'break', 'const', 'continue', 'crate', 'dyn',
  'else', 'enum', 'extern', 'false', 'fn', 'for', 'if', 'impl', 'in',
  'let', 'loop', 'match', 'mod', 'move', 'mut', 'pub', 'ref', 'return',
  'self', 'Self', 'static', 'struct', 'super', 'trait', 'true', 'type',
  'unsafe', 'use', 'where', 'while', 'yield',
};

const types = <String>{
  'i8', 'i16', 'i32', 'i64', 'i128', 'isize', 'u8', 'u16', 'u32', 'u64',
  'u128', 'usize', 'f32', 'f64', 'bool', 'char', 'str', 'String', 'Vec',
  'Option', 'Result', 'Box', 'Rc', 'Arc',
};

TextSpan highlightRust(String code, HighlightPalette palette) =>
    highlightGeneric(code, palette, keywords: keywords, types: types);
