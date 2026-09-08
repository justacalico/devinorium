import 'dart:typed_data';

import 'package:devinorium_frontend/state/app_state.dart';
import 'package:devinorium_frontend/utils/media_picker.dart';
import 'package:devinorium_frontend/views/drop_zone.dart';
import 'package:flutter/cupertino.dart' show CupertinoActionSheet;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart' show XFile;
import 'package:provider/provider.dart';

const _pngBytes = <int>[137, 80, 78, 71, 13, 10, 26, 10];

class _FakeMediaPicker implements MediaPicker {
  List<XFile> gallery = const [];
  XFile? photo;
  XFile? video;
  bool? requestedMultiple;

  @override
  Future<List<XFile>> pickGalleryMedia({required bool multiple}) async {
    requestedMultiple = multiple;
    return gallery;
  }

  @override
  Future<XFile?> capturePhoto() async => photo;

  @override
  Future<XFile?> captureVideo() async => video;
}

XFile _mediaFile(String name, String mimeType) => XFile.fromData(
  Uint8List.fromList(_pngBytes),
  path: name,
  mimeType: mimeType,
);

Widget _buildWithState(
  AppState state,
  _FakeMediaPicker picker,
  TargetPlatform platform,
) => MaterialApp(
  theme: ThemeData(platform: platform),
  home: ChangeNotifierProvider<AppState>.value(
    value: state,
    child: DropZone(
      mediaPicker: picker,
      child: const Scaffold(body: Center(child: Text('inside'))),
    ),
  ),
);

Future<List<({String filename, String mime, Uint8List bytes})>> _triggerPick(
  WidgetTester tester,
) {
  final context = tester.element(find.text('inside'));
  return DropZone.of(context)!.pick(multiple: true);
}

void main() {
  group('mobile attachment source picker', () {
    testWidgets('iOS offers photo library, camera and browse', (tester) async {
      final state = AppState.test();
      addTearDown(state.dispose);
      final picker = _FakeMediaPicker();

      await tester.pumpWidget(
        _buildWithState(state, picker, TargetPlatform.iOS),
      );
      await tester.pumpAndSettle();

      final pick = _triggerPick(tester);
      await tester.pumpAndSettle();
      expect(find.byType(CupertinoActionSheet), findsOneWidget);
      expect(find.text('Photo Library'), findsOneWidget);
      expect(find.text('Take Photo or Video'), findsOneWidget);
      expect(find.text('Browse'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(await pick, isEmpty);
    });

    testWidgets('iOS attaches photos from the gallery', (tester) async {
      final state = AppState.test();
      addTearDown(state.dispose);
      final picker = _FakeMediaPicker()
        ..gallery = [_mediaFile('shot.png', 'image/png')];

      await tester.pumpWidget(
        _buildWithState(state, picker, TargetPlatform.iOS),
      );
      await tester.pumpAndSettle();

      final pick = _triggerPick(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Photo Library'));
      await tester.pumpAndSettle();

      final files = await pick;
      expect(picker.requestedMultiple, isTrue);
      expect(files, hasLength(1));
      expect(files.first.filename, 'shot.png');
      expect(files.first.mime, 'image/png');
      expect(files.first.bytes, _pngBytes);
    });

    testWidgets('iOS attaches a captured photo', (tester) async {
      final state = AppState.test();
      addTearDown(state.dispose);
      final picker = _FakeMediaPicker()
        ..photo = _mediaFile('capture.jpg', 'image/jpeg');

      await tester.pumpWidget(
        _buildWithState(state, picker, TargetPlatform.iOS),
      );
      await tester.pumpAndSettle();

      final pick = _triggerPick(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Take Photo or Video'));
      await tester.pumpAndSettle();
      expect(find.text('Take Photo'), findsOneWidget);
      expect(find.text('Record Video'), findsOneWidget);

      await tester.tap(find.text('Take Photo'));
      await tester.pumpAndSettle();

      final files = await pick;
      expect(files, hasLength(1));
      expect(files.first.filename, 'capture.jpg');
      expect(files.first.mime, 'image/jpeg');
    });

    testWidgets('iOS attaches a captured video', (tester) async {
      final state = AppState.test();
      addTearDown(state.dispose);
      final picker = _FakeMediaPicker()
        ..video = _mediaFile('clip.mp4', 'video/mp4');

      await tester.pumpWidget(
        _buildWithState(state, picker, TargetPlatform.iOS),
      );
      await tester.pumpAndSettle();

      final pick = _triggerPick(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Take Photo or Video'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Record Video'));
      await tester.pumpAndSettle();

      final files = await pick;
      expect(files, hasLength(1));
      expect(files.first.filename, 'clip.mp4');
      expect(files.first.mime, 'video/mp4');
    });

    testWidgets('cancelling the camera sheet returns nothing', (tester) async {
      final state = AppState.test();
      addTearDown(state.dispose);
      final picker = _FakeMediaPicker();

      await tester.pumpWidget(
        _buildWithState(state, picker, TargetPlatform.iOS),
      );
      await tester.pumpAndSettle();

      final pick = _triggerPick(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Take Photo or Video'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(await pick, isEmpty);
    });

    testWidgets('Android offers a bottom sheet with the same sources', (
      tester,
    ) async {
      final state = AppState.test();
      addTearDown(state.dispose);
      final picker = _FakeMediaPicker()
        ..gallery = [_mediaFile('shot.png', 'image/png')];

      await tester.pumpWidget(
        _buildWithState(state, picker, TargetPlatform.android),
      );
      await tester.pumpAndSettle();

      final pick = _triggerPick(tester);
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.text('Photo Library'), findsOneWidget);
      expect(find.text('Take Photo or Video'), findsOneWidget);
      expect(find.text('Browse'), findsOneWidget);

      await tester.tap(find.text('Photo Library'));
      await tester.pumpAndSettle();

      final files = await pick;
      expect(files, hasLength(1));
      expect(files.first.filename, 'shot.png');
    });
  });
}
