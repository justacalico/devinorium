import 'package:flutter/material.dart';

import 'generic.dart';
import 'palette.dart';

const keywords = <String>{
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

TextSpan highlightSql(String code, HighlightPalette palette) =>
    highlightGeneric(code, palette, keywords: keywords, types: const {});
