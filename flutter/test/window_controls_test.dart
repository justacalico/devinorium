import 'package:devinorium_frontend/views/window_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _buildWithPlatform(TargetPlatform platform, Widget child) {
  return MaterialApp(
    theme: ThemeData(platform: platform, useMaterial3: true),
    home: Scaffold(
      body: Container(color: Colors.black, child: child),
    ),
  );
}

void main() {
  group('WindowControls', () {
    testWidgets('renders traffic lights on desktop', (tester) async {
      await tester.pumpWidget(
        _buildWithPlatform(TargetPlatform.linux, const WindowControls()),
      );

      expect(find.byKey(const Key('window_close_button')), findsOneWidget);
      expect(find.byKey(const Key('window_minimize_button')), findsOneWidget);
      expect(find.byKey(const Key('window_maximize_button')), findsOneWidget);
    });

    testWidgets('does not render on non-desktop platforms', (tester) async {
      await tester.pumpWidget(
        _buildWithPlatform(TargetPlatform.iOS, const WindowControls()),
      );

      expect(find.byKey(const Key('window_close_button')), findsNothing);
      expect(find.byKey(const Key('window_minimize_button')), findsNothing);
      expect(find.byKey(const Key('window_maximize_button')), findsNothing);
    });
  });
}
