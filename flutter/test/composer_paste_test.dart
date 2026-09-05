import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:devinorium_frontend/utils/clipboard_image.dart';
import 'package:devinorium_frontend/views/thread_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

const _platformChannel = OptionalMethodChannel(
  'flutter/platform',
  JSONMethodCodec(),
);

const _pngBytes = <int>[
  137,
  80,
  78,
  71,
  13,
  10,
  26,
  10,
  0,
  0,
  0,
  13,
  73,
  72,
  68,
  82,
];

Widget _buildWithState(AppState state) => MaterialApp(
  home: ChangeNotifierProvider<AppState>.value(
    value: state,
    child: const ThreadPage(),
  ),
);

AppState _testState() => AppState.test(
  user: User(
    id: 1,
    username: 'owner',
    role: 'user',
    totpEnabled: false,
    isOwner: true,
    providerId: 'devin-cli',
    providerCommand: 'devin',
  ),
  activeThreadId: 't1',
  activeThreadDetail: ThreadDetail(
    thread: Thread(
      id: 't1',
      title: 'Test',
      projectId: 1,
      model: 'm1',
      permissionMode: 'normal',
      createdAt: '',
      updatedAt: '',
    ),
    messages: const [],
  ),
);

void main() {
  group('composer paste', () {
    tearDown(() {
      setTestClipboardImageGetter(null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_platformChannel, null);
    });

    testWidgets('attaches an image from the clipboard', (tester) async {
      setTestClipboardImageGetter(
        () => Future.value(Uint8List.fromList(_pngBytes)),
      );

      final state = _testState();

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      final textField = find.byKey(const Key('composer_input'));
      await tester.tap(textField);
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      expect(state.attachments, hasLength(1));
      expect(state.attachments.first.filename, 'pasted-image.png');
      expect(state.attachments.first.mime, 'image/png');
      expect(state.attachments.first.bytes, _pngBytes);
    });

    testWidgets('falls back to text when clipboard has no image', (
      tester,
    ) async {
      setTestClipboardImageGetter(() => Future.value(null));
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        _platformChannel,
        (call) async {
          if (call.method == 'Clipboard.getData') {
            return <String, dynamic>{'text': 'hello'};
          }
          return null;
        },
      );

      final state = _testState();

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('composer_input')));
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      expect(state.attachments, isEmpty);
      expect(state.composerText, 'hello');
    });


  });
}
