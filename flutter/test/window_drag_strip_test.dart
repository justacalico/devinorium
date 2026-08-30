import 'package:devinorium_frontend/views/window_drag_strip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _buildWithPlatform(TargetPlatform platform, Widget child) {
  return MaterialApp(
    theme: ThemeData(platform: platform, useMaterial3: true),
    home: child,
  );
}

void main() {
  group('WindowDragStrip', () {
    testWidgets('overlays drag strip on desktop', (tester) async {
      await tester.pumpWidget(
        _buildWithPlatform(
          TargetPlatform.linux,
          const WindowDragStrip(child: SizedBox.expand()),
        ),
      );

      expect(find.byKey(const Key('window_drag_strip')), findsOneWidget);
    });

    testWidgets('passes child through on mobile', (tester) async {
      await tester.pumpWidget(
        _buildWithPlatform(
          TargetPlatform.iOS,
          const WindowDragStrip(
            child: Text('child'),
          ),
        ),
      );

      expect(find.byKey(const Key('window_drag_strip')), findsNothing);
      expect(find.text('child'), findsOneWidget);
    });
  });
}
