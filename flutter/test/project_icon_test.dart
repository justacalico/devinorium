import 'dart:convert';
import 'dart:typed_data';

import 'package:devinorium_frontend/views/project_icon.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
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
        colors.add(projectIconForType(t).color.toARGB32());
      }
      expect(colors.length, types.length);
    });
  });

  group('ProjectIconImage', () {
    const fallback = SizedBox(key: Key('fallback'));

    // 1x1 transparent PNG.
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ'
      'AAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
    );

    testWidgets('renders raster bytes through Image', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ProjectIconImage(
            icon: (mime: 'image/png', bytes: png),
            fallback: fallback,
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(Image), findsOneWidget);
      expect(find.byKey(const Key('fallback')), findsNothing);
    });

    testWidgets('renders svg bytes through SvgPicture', (tester) async {
      final svg = Uint8List.fromList(
        utf8.encode(
          '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16">'
          '<rect width="16" height="16"/></svg>',
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: ProjectIconImage(
            icon: (mime: 'image/svg+xml', bytes: svg),
            fallback: fallback,
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(SvgPicture), findsOneWidget);
    });

    testWidgets('shows the fallback for undecodable bytes', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ProjectIconImage(
            icon: (mime: 'image/png', bytes: Uint8List.fromList([1, 2, 3])),
            fallback: fallback,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('fallback')), findsOneWidget);
    });
  });
}
