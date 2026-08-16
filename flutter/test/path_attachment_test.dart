import 'dart:io';

import 'package:devinorium_frontend/utils/path_attachment.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('maybeAttachPath', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('path_attachment_test');
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('attaches an absolute Linux/macOS file path', () async {
      final file = File('${tempDir.path}/test.txt');
      await file.writeAsString('hello');

      final result = await maybeAttachPath(file.absolute.path);

      expect(result, isA<PathAttached>());
      final attached = result as PathAttached;
      expect(attached.filename, 'test.txt');
      expect(attached.mime, 'text/plain');
      expect(attached.bytes, equals([104, 101, 108, 108, 111]));
    });

    test('attaches a file:// URI', () async {
      final file = File('${tempDir.path}/image.png');
      final data = <int>[137, 80, 78, 71, 13, 10, 26, 10];
      await file.writeAsBytes(data);

      final result = await maybeAttachPath('file://${file.absolute.path}');

      expect(result, isA<PathAttached>());
      final attached = result as PathAttached;
      expect(attached.filename, 'image.png');
      expect(attached.mime, 'image/png');
      expect(attached.bytes, equals(data));
    });

    test('falls back to paste for a Windows-style path that does not exist',
        () async {
      const path = r'C:\Users\foo\bar.txt';

      final result = await maybeAttachPath(path);

      expect(result, isA<PathFallback>());
    });

    test('falls back to paste for a directory path', () async {
      final dir = Directory('${tempDir.path}/a_dir');
      await dir.create();

      final result = await maybeAttachPath(dir.absolute.path);

      expect(result, isA<PathFallback>());
    });

    test('falls back to paste for a non-existent path', () async {
      final result = await maybeAttachPath('${tempDir.path}/missing.txt');

      expect(result, isA<PathFallback>());
    });

    test('returns too large for files above 8 MB', () async {
      final file = File('${tempDir.path}/big.bin');
      const size = 8 * 1024 * 1024 + 1;
      await file.writeAsBytes(List.filled(size, 0));

      final result = await maybeAttachPath(file.absolute.path);

      expect(result, isA<PathTooLarge>());
      final tooLarge = result as PathTooLarge;
      expect(tooLarge.filename, 'big.bin');
      expect(tooLarge.size, size);
    });
  });
}
