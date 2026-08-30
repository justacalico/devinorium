import 'package:devinorium_frontend/views/window_title_drag.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _buildWithPlatform(TargetPlatform platform, Widget child) {
  return MaterialApp(
    theme: ThemeData(platform: platform, useMaterial3: true),
    home: Scaffold(
      appBar: AppBar(
        leading: const Icon(Icons.menu),
        title: child,
        actions: const [Icon(Icons.folder_outlined)],
      ),
    ),
  );
}

void main() {
  group('WindowTitleDrag', () {
    testWidgets('wraps title on desktop', (tester) async {
      await tester.pumpWidget(
        _buildWithPlatform(
          TargetPlatform.linux,
          const WindowTitleDrag(
            key: Key('title_drag'),
            child: Text('title'),
          ),
        ),
      );

      expect(find.byKey(const Key('title_drag')), findsOneWidget);
      expect(find.text('title'), findsOneWidget);
    });

    testWidgets('does not wrap leading or action buttons', (tester) async {
      await tester.pumpWidget(
        _buildWithPlatform(
          TargetPlatform.linux,
          const WindowTitleDrag(
            key: Key('title_drag'),
            child: Text('title'),
          ),
        ),
      );

      expect(
        find.ancestor(
          of: find.byIcon(Icons.menu),
          matching: find.byKey(const Key('title_drag')),
        ),
        findsNothing,
      );
      expect(
        find.ancestor(
          of: find.byIcon(Icons.folder_outlined),
          matching: find.byKey(const Key('title_drag')),
        ),
        findsNothing,
      );
    });

    testWidgets('passes child through on mobile', (tester) async {
      await tester.pumpWidget(
        _buildWithPlatform(
          TargetPlatform.iOS,
          const WindowTitleDrag(child: Text('title')),
        ),
      );

      expect(find.byType(GestureDetector), findsNothing);
      expect(find.text('title'), findsOneWidget);
    });
  });
}
