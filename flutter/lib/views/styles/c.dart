import 'package:flutter/material.dart';

import 'palette.dart';
import 'tokenizer.dart';

const keywords = <String>{
  'alignas',
  'alignof',
  'and',
  'and_eq',
  'asm',
  'auto',
  'bitand',
  'bitor',
  'break',
  'case',
  'catch',
  'class',
  'co_await',
  'co_return',
  'co_yield',
  'compl',
  'concept',
  'const',
  'consteval',
  'constexpr',
  'constinit',
  'continue',
  'decltype',
  'default',
  'delete',
  'do',
  'else',
  'enum',
  'explicit',
  'export',
  'extern',
  'false',
  'final',
  'for',
  'friend',
  'goto',
  'if',
  'import',
  'inline',
  'module',
  'mutable',
  'namespace',
  'new',
  'noexcept',
  'not',
  'not_eq',
  'nullptr',
  'operator',
  'or',
  'or_eq',
  'override',
  'private',
  'protected',
  'public',
  'register',
  'requires',
  'restrict',
  'return',
  'sizeof',
  'static',
  'static_assert',
  'struct',
  'switch',
  'template',
  'this',
  'thread_local',
  'throw',
  'true',
  'try',
  'typedef',
  'typeid',
  'typename',
  'union',
  'using',
  'virtual',
  'volatile',
  'while',
  'xor',
  'xor_eq',
  'const_cast',
  'dynamic_cast',
  'reinterpret_cast',
  'static_cast',
  '_Alignas',
  '_Alignof',
  '_Atomic',
  '_Bool',
  '_Generic',
  '_Noreturn',
  '_Static_assert',
  '_Thread_local',
  'typeof',
  '__alignof__',
  '__asm__',
  '__attribute__',
  '__declspec',
  '__extension__',
  '__inline__',
  '__restrict',
  '__typeof__',
  '__volatile__',
};

const types = <String>{
  'bool',
  'char',
  'char8_t',
  'char16_t',
  'char32_t',
  'double',
  'float',
  'int',
  'long',
  'short',
  'signed',
  'unsigned',
  'void',
  'wchar_t',
  'size_t',
  'ssize_t',
  'ptrdiff_t',
  'intptr_t',
  'uintptr_t',
  'int8_t',
  'int16_t',
  'int32_t',
  'int64_t',
  'uint8_t',
  'uint16_t',
  'uint32_t',
  'uint64_t',
  'off_t',
  'pid_t',
  'FILE',
  'std',
  'string',
  'string_view',
  'vector',
  'map',
  'set',
  'unordered_map',
  'unordered_set',
  'pair',
  'tuple',
  'array',
  'deque',
  'list',
  'queue',
  'stack',
  'optional',
  'variant',
  'function',
  'span',
  'unique_ptr',
  'shared_ptr',
  'weak_ptr',
  'ostream',
  'istream',
  'byte',
  'any',
  'expected',
  'nullptr_t',
};

const csharpKeywords = <String>{
  'abstract',
  'as',
  'ascending',
  'async',
  'await',
  'base',
  'by',
  'checked',
  'delegate',
  'descending',
  'dynamic',
  'equals',
  'event',
  'finally',
  'fixed',
  'foreach',
  'from',
  'get',
  'global',
  'group',
  'in',
  'init',
  'internal',
  'into',
  'is',
  'join',
  'let',
  'lock',
  'nameof',
  'null',
  'on',
  'orderby',
  'out',
  'params',
  'partial',
  'readonly',
  'record',
  'ref',
  'sealed',
  'select',
  'set',
  'stackalloc',
  'unchecked',
  'unsafe',
  'value',
  'var',
  'when',
  'where',
  'yield',
  'implicit',
  'interface',
  'notnull',
  'required',
  'scoped',
  'with',
};

const csharpTypes = <String>{
  'sbyte',
  'uint',
  'ulong',
  'ushort',
  'decimal',
  'nint',
  'nuint',
  'object',
  'Boolean',
  'Byte',
  'Char',
  'DateTime',
  'Decimal',
  'Dictionary',
  'Double',
  'Exception',
  'Guid',
  'IEnumerable',
  'IList',
  'Int16',
  'Int32',
  'Int64',
  'List',
  'Math',
  'Object',
  'Single',
  'String',
  'Task',
  'TimeSpan',
  'ValueTask',
  'Console',
};

const objcKeywords = <String>{
  'autoreleasepool',
  'bycopy',
  'byref',
  'defs',
  'encode',
  'end',
  'IBAction',
  'IBOutlet',
  'implementation',
  'in',
  'instancetype',
  'interface',
  'nil',
  'Nil',
  'NO',
  'oneway',
  'optional',
  'out',
  'package',
  'property',
  'protocol',
  'required',
  'selector',
  'self',
  'super',
  'synthesize',
  'YES',
  'dynamic',
  '__block',
  '__strong',
  '__unsafe_unretained',
  '__weak',
};

TextSpan highlightC(String code, HighlightPalette palette) =>
    _highlight(code, palette);

TextSpan highlightCSharp(String code, HighlightPalette palette) => _highlight(
  code,
  palette,
  extraKeywords: csharpKeywords,
  extraTypes: csharpTypes,
);

TextSpan highlightObjC(String code, HighlightPalette palette) => _highlight(
  code,
  palette,
  extraKeywords: objcKeywords,
  extraTypes: const {'id'},
);

final _leadingDigit = RegExp(r'^\d');
final _capitalized = RegExp(r'^[A-Z]');

TextSpan _highlight(
  String code,
  HighlightPalette palette, {
  Set<String> extraKeywords = const {},
  Set<String> extraTypes = const {},
}) {
  final spans = <TextSpan>[];
  final regex = RegExp(
    r'//[^\n]*|/\*[\s\S]*?\*/|#[^\n]*|"(?:[^"\\]|\\.)*"|'
    r"'(?:[^'\\\n]|\\.)*'"
    r"|\b0[xX][0-9a-fA-F']+[uUlL]*\b|\b0[bB][01']+[uUlL]*\b|"
    r"\b\d[\d']*\.?[\d']*(?:[eE][+-]?\d+)?[fFlLuUzZ]*\b|"
    r'\b\w+\b|[^\s\w]',
  );
  tokenize(code, regex, spans, palette, (match) {
    final t = match[0]!;
    if (t.startsWith('//') || t.startsWith('/*')) {
      return span(t, palette.comment, style: FontStyle.italic);
    }
    if (t.startsWith('#')) {
      return _directive(t, palette);
    }
    if ((t.startsWith('"') || t.startsWith("'")) && t.length > 1) {
      return span(t, palette.string);
    }
    if (_leadingDigit.hasMatch(t)) {
      return span(t, palette.number);
    }
    if (keywords.contains(t) || extraKeywords.contains(t)) {
      return span(t, palette.keyword, weight: FontWeight.w600);
    }
    if (types.contains(t) ||
        extraTypes.contains(t) ||
        _capitalized.hasMatch(t)) {
      return span(t, palette.type);
    }
    return span(t, palette.base);
  });
  return TextSpan(children: spans);
}

TextSpan _directive(String line, HighlightPalette palette) {
  final children = <TextSpan>[];
  final regex = RegExp(
    r'//[^\n]*|/\*[\s\S]*?\*/|#[ \t]*\w+|<[^>\s]+>|"(?:[^"\\]|\\.)*"|'
    r"\b0[xX][0-9a-fA-F']+[uUlL]*\b|\b0[bB][01']+[uUlL]*\b|"
    r"\b\d[\d']*\.?[\d']*(?:[eE][+-]?\d+)?[fFlLuUzZ]*\b",
  );
  tokenize(line, regex, children, palette, (match) {
    final t = match[0]!;
    if (t.startsWith('#')) {
      return span(t, palette.keyword, weight: FontWeight.w600);
    }
    if (t.startsWith('//') || t.startsWith('/*')) {
      return span(t, palette.comment, style: FontStyle.italic);
    }
    if (_leadingDigit.hasMatch(t)) {
      return span(t, palette.number);
    }
    return span(t, palette.string);
  });
  return TextSpan(children: children);
}
