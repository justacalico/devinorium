import 'package:devinorium_frontend/views/dev_merge_request_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _mrId = '42';
const _mrUrl = 'https://gitlab.com/HttpAnimations/devinorium/-/merge_requests/42';

void main() {
  String? clipboardText;

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (
          MethodCall call,
        ) async {
          switch (call.method) {
            case 'Clipboard.setData':
              final args = call.arguments as Map<dynamic, dynamic>;
              clipboardText = args['text'] as String?;
              return null;
            case 'Clipboard.getData':
              return {'text': clipboardText};
          }
          return null;
        });
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  group('DevMergeRequestWrapper', () {
    setUp(() => clipboardText = null);

    testWidgets('shows a startup dialog when a merge request ID is set', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: DevMergeRequestWrapper(
            mergeRequestId: _mrId,
            mergeRequestUrl: _mrUrl,
            child: SizedBox.expand(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('Development merge request'), findsOneWidget);
      expect(find.text(_mrUrl), findsOneWidget);
      expect(find.text('Open'), findsOneWidget);
      expect(find.text('Copy'), findsOneWidget);
      expect(find.text('Close'), findsOneWidget);
    });

    testWidgets('does not show a dialog when no merge request ID is set', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: DevMergeRequestWrapper(child: SizedBox.expand()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('dialog can be dismissed with the Close button', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: DevMergeRequestWrapper(
            mergeRequestId: _mrId,
            mergeRequestUrl: _mrUrl,
            child: SizedBox.expand(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('Copy button writes the merge request URL to the clipboard', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: DevMergeRequestWrapper(
            mergeRequestId: _mrId,
            mergeRequestUrl: _mrUrl,
            child: SizedBox.expand(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Copy'));
      await tester.pumpAndSettle();

      final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
      expect(clipboard?.text, _mrUrl);
    });

    testWidgets('hides URL and actions when the URL is missing', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: DevMergeRequestWrapper(
            mergeRequestId: _mrId,
            mergeRequestUrl: '',
            child: SizedBox.expand(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('Development merge request'), findsOneWidget);
      expect(find.text('Open'), findsNothing);
      expect(find.text('Copy'), findsNothing);
      expect(find.byType(SelectableText), findsNothing);
      expect(find.text('Close'), findsOneWidget);
    });

    testWidgets('hides URL and actions when the URL is not an http(s) link', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: DevMergeRequestWrapper(
            mergeRequestId: _mrId,
            mergeRequestUrl: 'not-a-url',
            child: SizedBox.expand(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('Development merge request'), findsOneWidget);
      expect(find.text('Open'), findsNothing);
      expect(find.text('Copy'), findsNothing);
      expect(find.byType(SelectableText), findsNothing);
      expect(find.text('Close'), findsOneWidget);
    });
  });
}
