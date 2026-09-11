import 'package:devinorium_frontend/widgets/message_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host({void Function(BuildContext)? onPressed}) {
  return MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () => onPressed?.call(context),
          child: const Text('show'),
        ),
      ),
    ),
  );
}

void main() {
  group('MessageView', () {
    testWidgets('renders message text', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: MessageView(message: 'Something happened')),
        ),
      );
      expect(find.text('Something happened'), findsOneWidget);
      expect(find.byIcon(Icons.info_outline), findsOneWidget);
    });

    testWidgets('renders an icon per kind', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                MessageView(message: 'a', kind: MessageKind.success),
                MessageView(message: 'b', kind: MessageKind.warning),
                MessageView(message: 'c', kind: MessageKind.error),
              ],
            ),
          ),
        ),
      );
      expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
    });

    testWidgets('shows a close button when onDismiss is set', (tester) async {
      var dismissed = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MessageView(
              message: 'dismiss me',
              onDismiss: () => dismissed = true,
            ),
          ),
        ),
      );
      await tester.tap(find.byIcon(Icons.close));
      expect(dismissed, isTrue);
    });

    testWidgets('hides the close button without onDismiss', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: MessageView(message: 'no close')),
        ),
      );
      expect(find.byIcon(Icons.close), findsNothing);
    });
  });

  group('showAppMessage', () {
    testWidgets('shows a message above the app', (tester) async {
      await tester.pumpWidget(
        _host(
          onPressed: (context) =>
              showAppMessage(context, 'saved', kind: MessageKind.success),
        ),
      );
      await tester.tap(find.text('show'));
      await tester.pumpAndSettle();
      expect(find.text('saved'), findsOneWidget);
      expect(find.byType(MessageView), findsOneWidget);
    });

    testWidgets('dismisses itself after the duration', (tester) async {
      await tester.pumpWidget(
        _host(
          onPressed: (context) => showAppMessage(
            context,
            'gone soon',
            duration: const Duration(seconds: 2),
          ),
        ),
      );
      await tester.tap(find.text('show'));
      await tester.pumpAndSettle();
      expect(find.text('gone soon'), findsOneWidget);

      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.text('gone soon'), findsNothing);
    });

    testWidgets('close button removes the message', (tester) async {
      await tester.pumpWidget(
        _host(
          onPressed: (context) => showAppMessage(context, 'close me'),
        ),
      );
      await tester.tap(find.text('show'));
      await tester.pumpAndSettle();
      expect(find.text('close me'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      expect(find.text('close me'), findsNothing);
    });

    testWidgets('identical messages do not stack', (tester) async {
      var count = 0;
      await tester.pumpWidget(
        _host(
          onPressed: (context) {
            showAppMessage(context, 'same');
            count++;
          },
        ),
      );
      await tester.tap(find.text('show'));
      await tester.tap(find.text('show'));
      await tester.pumpAndSettle();
      expect(count, 2);
      expect(find.text('same'), findsOneWidget);
    });

    testWidgets('reshowing a message restarts its timer', (tester) async {
      await tester.pumpWidget(
        _host(
          onPressed: (context) => showAppMessage(
            context,
            'still here',
            duration: const Duration(seconds: 4),
          ),
        ),
      );
      await tester.tap(find.text('show'));
      await tester.pumpAndSettle();

      await tester.pump(const Duration(seconds: 3));
      await tester.tap(find.text('show'));
      await tester.pumpAndSettle();
      expect(find.text('still here'), findsOneWidget);

      // 6 seconds in total, but the restarted timer still has time left.
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('still here'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.text('still here'), findsNothing);
    });

    testWidgets('does not overflow on a short viewport', (tester) async {
      tester.view.physicalSize = const Size(800, 200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        _host(
          onPressed: (context) {
            for (var i = 0; i < 3; i++) {
              showAppMessage(context, 'tall message $i ' * 8);
            }
          },
        ),
      );
      await tester.tap(find.text('show'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('caps the visible stack', (tester) async {
      await tester.pumpWidget(
        _host(
          onPressed: (context) {
            for (var i = 0; i < 5; i++) {
              showAppMessage(context, 'message $i');
            }
          },
        ),
      );
      await tester.tap(find.text('show'));
      await tester.pumpAndSettle();
      // The oldest messages were dismissed once the cap was hit; they may
      // still be animating out, so only count what remains after settling.
      expect(find.byType(MessageView), findsNWidgets(3));
      expect(find.text('message 0'), findsNothing);
      expect(find.text('message 1'), findsNothing);
      expect(find.text('message 4'), findsOneWidget);
    });

    testWidgets('does nothing without an overlay', (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showAppMessage(context, 'nowhere'),
              child: const Text('show'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('show'));
      await tester.pumpAndSettle();
      expect(find.text('nowhere'), findsNothing);
    });
  });
}
