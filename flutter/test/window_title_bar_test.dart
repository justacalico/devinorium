import 'package:devinorium_frontend/views/window_title_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _buildWithPlatform(TargetPlatform platform, Widget child) {
  return MaterialApp(
    theme: ThemeData(platform: platform, useMaterial3: true),
    home: child,
  );
}

void main() {
  group('WindowTitleBar', () {
    testWidgets('renders controls on desktop', (tester) async {
      await tester.pumpWidget(
        _buildWithPlatform(
          TargetPlatform.linux,
          const Scaffold(
            body: WindowTitleBar(),
          ),
        ),
      );

      expect(find.text('Devinorium'), findsNothing);
      expect(find.byIcon(Icons.remove), findsOneWidget);
      expect(find.byIcon(Icons.crop_square), findsOneWidget);
      expect(find.byIcon(Icons.close), findsOneWidget);
    });

    testWidgets('does not render on non-desktop platforms', (tester) async {
      await tester.pumpWidget(
        _buildWithPlatform(
          TargetPlatform.iOS,
          const Scaffold(
            body: WindowTitleBar(),
          ),
        ),
      );

      expect(find.text('Devinorium'), findsNothing);
      expect(find.byIcon(Icons.remove), findsNothing);
      expect(find.byIcon(Icons.crop_square), findsNothing);
      expect(find.byIcon(Icons.close), findsNothing);
    });
  });
}
