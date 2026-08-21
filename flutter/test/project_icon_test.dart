import 'package:devinorium_frontend/views/project_icon.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('projectIconForType', () {
    test('returns flutter icon for flutter type', () {
      final icon = projectIconForType('flutter');
      expect(icon.icon, Icons.flutter_dash);
    });

    test('returns rust icon for rust type', () {
      final icon = projectIconForType('rust');
      expect(icon.icon, Icons.build);
    });

    test('returns node icon for node type', () {
      final icon = projectIconForType('node');
      expect(icon.icon, Icons.javascript);
    });

    test('returns python icon for python type', () {
      final icon = projectIconForType('python');
      expect(icon.icon, Icons.code);
    });

    test('returns go icon for go type', () {
      final icon = projectIconForType('go');
      expect(icon.icon, Icons.rocket_launch);
    });

    test('returns generic folder icon for unknown type', () {
      final icon = projectIconForType('generic');
      expect(icon.icon, Icons.folder_outlined);
    });

    test('returns generic folder icon for empty type', () {
      final icon = projectIconForType('');
      expect(icon.icon, Icons.folder_outlined);
    });

    test('returns generic folder icon for unknown string', () {
      final icon = projectIconForType('foobar');
      expect(icon.icon, Icons.folder_outlined);
    });

    test('each type has a distinct color', () {
      final types = ['flutter', 'rust', 'node', 'python', 'go', 'java', 'generic'];
      final colors = <int>{};
      for (final t in types) {
        colors.add(projectIconForType(t).color.value);
      }
      expect(colors.length, types.length);
    });
  });
}
