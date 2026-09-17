import 'dart:typed_data';

import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:devinorium_frontend/utils/media_picker.dart';
import 'package:devinorium_frontend/views/drop_zone.dart';
import 'package:devinorium_frontend/views/thread_page.dart';
import 'package:devinorium_frontend/widgets/attachment_thumbnail.dart';
import 'package:flutter/cupertino.dart' show CupertinoActionSheet;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart' show XFile;
import 'package:provider/provider.dart';

const _pngBytes = <int>[137, 80, 78, 71, 13, 10, 26, 10];

class _FakeMediaPicker implements MediaPicker {
  List<XFile> gallery = const [];

  @override
  Future<List<XFile>> pickGalleryMedia({required bool multiple}) async =>
      gallery;

  @override
  Future<XFile?> capturePhoto() async => null;

  @override
  Future<XFile?> captureVideo() async => null;
}

XFile _mediaFile(String name, String mimeType) => XFile.fromData(
  Uint8List.fromList(_pngBytes),
  path: name,
  mimeType: mimeType,
);

Widget _buildWithState(
  AppState state, {
  TargetPlatform platform = TargetPlatform.android,
  MediaPicker? mediaPicker,
}) => MaterialApp(
  theme: ThemeData(platform: platform),
  home: ChangeNotifierProvider<AppState>.value(
    value: state,
    child: DropZone(mediaPicker: mediaPicker, child: const ThreadPage()),
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
  group('composer attachment chips', () {
    testWidgets('appear immediately when attachments are added', (
      tester,
    ) async {
      final state = _testState();
      addTearDown(state.dispose);

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      expect(find.text('photo.png'), findsNothing);

      state.addAttachments([
        (filename: 'photo.png', mime: 'image/png', bytes: Uint8List(0)),
      ]);
      await tester.pump();

      expect(find.text('photo.png'), findsOneWidget);
    });

    testWidgets('disappear immediately when attachments are cleared', (
      tester,
    ) async {
      final state = _testState();
      addTearDown(state.dispose);

      state.addAttachments([
        (filename: 'photo.png', mime: 'image/png', bytes: Uint8List(0)),
      ]);

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      expect(find.text('photo.png'), findsOneWidget);

      state.clearAttachments();
      await tester.pump();

      expect(find.text('photo.png'), findsNothing);
    });

    testWidgets('iOS photo library selection shows the chip immediately', (
      tester,
    ) async {
      final state = _testState();
      addTearDown(state.dispose);

      final picker = _FakeMediaPicker()
        ..gallery = [_mediaFile('image_picker_62424085.png', 'image/png')];

      await tester.pumpWidget(
        _buildWithState(
          state,
          platform: TargetPlatform.iOS,
          mediaPicker: picker,
        ),
      );
      await tester.pumpAndSettle();

      // Tap the attach button to open the source sheet.
      await tester.tap(find.widgetWithIcon(IconButton, Icons.attach_file));
      await tester.pumpAndSettle();

      expect(find.byType(CupertinoActionSheet), findsOneWidget);

      // Choose the photo library.
      await tester.tap(find.text('Photo Library'));
      await tester.pumpAndSettle();

      // The attachment chip should render as soon as the file is added.
      expect(find.text('image_picker_62424085.png'), findsOneWidget);
      expect(state.attachments, hasLength(1));
    });

    testWidgets('image attachments render thumbnails instead of chips', (
      tester,
    ) async {
      final state = _testState();
      addTearDown(state.dispose);

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      state.addAttachments([
        (
          filename: 'photo.png',
          mime: 'image/png',
          bytes: Uint8List.fromList(_pngBytes),
        ),
        (filename: 'notes.txt', mime: 'text/plain', bytes: Uint8List(3)),
      ]);
      await tester.pump();

      // The image gets a thumbnail tile; the text file keeps its chip.
      expect(find.byType(AttachmentThumb), findsOneWidget);
      expect(find.text('photo.png'), findsOneWidget);
      expect(find.widgetWithText(Chip, 'notes.txt'), findsOneWidget);
    });

    testWidgets('thumbnail delete button removes the attachment', (
      tester,
    ) async {
      final state = _testState();
      addTearDown(state.dispose);

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      state.addAttachments([
        (
          filename: 'photo.png',
          mime: 'image/png',
          bytes: Uint8List.fromList(_pngBytes),
        ),
      ]);
      await tester.pump();

      expect(find.byType(AttachmentThumb), findsOneWidget);

      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();

      expect(state.attachments, isEmpty);
      expect(find.byType(AttachmentThumb), findsNothing);
    });

    testWidgets('attachments stay on one horizontally scrolling row', (
      tester,
    ) async {
      final state = _testState();
      addTearDown(state.dispose);

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      state.addAttachments([
        for (var i = 0; i < 8; i++)
          (
            filename: 'photo_$i.png',
            mime: 'image/png',
            bytes: Uint8List.fromList(_pngBytes),
          ),
      ]);
      await tester.pump();

      final scroll = tester.widget<SingleChildScrollView>(
        find.byKey(const Key('composer_attachments')),
      );
      expect(scroll.scrollDirection, Axis.horizontal);

      // Every thumbnail shares the same top edge; a second row would push
      // the text field down like the old Wrap did.
      final tops = {
        for (var i = 0; i < 8; i++)
          tester.getTopLeft(find.byKey(Key('composer_attachment_$i'))).dy,
      };
      expect(tops, hasLength(1));
    });

    testWidgets('overflowing attachments auto-scroll to the newest item', (
      tester,
    ) async {
      final state = _testState();
      addTearDown(state.dispose);

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      state.addAttachments([
        for (var i = 0; i < 8; i++)
          (
            filename: 'photo_$i.png',
            mime: 'image/png',
            bytes: Uint8List.fromList(_pngBytes),
          ),
      ]);
      await tester.pump();
      await tester.pump();

      final strip = tester.getRect(
        find.byKey(const Key('composer_attachments')),
      );
      final first = find.byKey(const Key('composer_attachment_0'));
      final last = find.byKey(const Key('composer_attachment_7'));

      // The strip jumped to the end so the just-added thumbnail is on
      // screen; the oldest item is scrolled off the left edge.
      expect(tester.getTopLeft(last).dx, lessThan(strip.right));
      expect(tester.getTopLeft(first).dx, lessThan(strip.left));

      // The user can still scroll back to the first items.
      await tester.drag(
        find.byKey(const Key('composer_attachments')),
        const Offset(400, 0),
      );
      await tester.pump();

      expect(tester.getTopLeft(first).dx, greaterThanOrEqualTo(strip.left));
    });
  });
}
