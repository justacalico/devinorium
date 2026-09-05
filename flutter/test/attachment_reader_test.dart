import 'dart:typed_data';

import 'package:devinorium_frontend/utils/attachment_reader.dart';
import 'package:flutter_test/flutter_test.dart';

class _ThrowingSource implements AttachmentSource {
  @override
  final String name;

  _ThrowingSource(this.name);

  @override
  String? get mimeType => null;

  @override
  Future<int> length() => Future.value(4);

  @override
  Future<Uint8List> readAsBytes() =>
      Future.error(StateError('disk full'));
}

void main() {
  group('readAttachment', () {
    test('returns a file attachment with detected mime type', () async {
      const pngBytes = <int>[
        137,
        80,
        78,
        71,
        13,
        10,
        26,
        10,
      ];
      final source = InMemoryAttachmentSource(
        'image.png',
        Uint8List.fromList(pngBytes),
      );

      final result = await readAttachment(source);

      expect(result, isA<AttachmentSuccess>());
      final success = result as AttachmentSuccess;
      expect(success.attachment.filename, 'image.png');
      expect(success.attachment.mime, 'image/png');
      expect(success.attachment.bytes, pngBytes);
    });

    test('uses the provided mime type when available', () async {
      final source = InMemoryAttachmentSource(
        'unknown.xyz',
        Uint8List.fromList([1, 2, 3]),
        mime: 'application/custom',
      );

      final result = await readAttachment(source);

      expect(result, isA<AttachmentSuccess>());
      final success = result as AttachmentSuccess;
      expect(success.attachment.mime, 'application/custom');
    });

    test('returns too large for oversized files', () async {
      final source = InMemoryAttachmentSource(
        'big.bin',
        Uint8List(8 * 1024 * 1024 + 1),
      );

      final result = await readAttachment(source);

      expect(result, isA<AttachmentTooLarge>());
      final tooLarge = result as AttachmentTooLarge;
      expect(tooLarge.filename, 'big.bin');
      expect(tooLarge.size, 8 * 1024 * 1024 + 1);
    });

    test('returns an error when reading fails', () async {
      final source = _ThrowingSource('bad.txt');

      final result = await readAttachment(source);

      expect(result, isA<AttachmentReadError>());
      final error = result as AttachmentReadError;
      expect(error.filename, 'bad.txt');
      expect('${error.error}', contains('disk full'));
    });

    test('falls back from empty mime type to detected type', () async {
      final source = InMemoryAttachmentSource(
        'image.png',
        Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10]),
        mime: '',
      );

      final result = await readAttachment(source);

      expect(result, isA<AttachmentSuccess>());
      final success = result as AttachmentSuccess;
      expect(success.attachment.mime, 'image/png');
    });

    test('returns too large when read bytes exceed the limit', () async {
      final source = _LargeReadSource('big.bin');

      final result = await readAttachment(source);

      expect(result, isA<AttachmentTooLarge>());
      final tooLarge = result as AttachmentTooLarge;
      expect(tooLarge.filename, 'big.bin');
      expect(tooLarge.size, 8 * 1024 * 1024 + 1);
    });
  });
}

class _LargeReadSource implements AttachmentSource {
  @override
  final String name;

  _LargeReadSource(this.name);

  @override
  String? get mimeType => null;

  @override
  Future<int> length() => Future.value(4);

  @override
  Future<Uint8List> readAsBytes() =>
      Future.value(Uint8List(8 * 1024 * 1024 + 1));
}
