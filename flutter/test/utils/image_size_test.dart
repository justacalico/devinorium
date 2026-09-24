import 'dart:convert';
import 'dart:typed_data';

import 'package:devinorium_frontend/utils/image_size.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('intrinsicImageSize', () {
    test('reads png dimensions from the IHDR', () {
      const png =
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
      expect(intrinsicImageSize(base64Decode(png)), (1, 1));
    });

    test('reads gif dimensions', () {
      final gif = Uint8List.fromList([
        0x47, 0x49, 0x46, 0x38, 0x39, 0x61, // GIF89a
        0x80, 0x02, 0xE0, 0x01, // 640x480 little-endian
      ]);
      expect(intrinsicImageSize(gif), (640, 480));
    });

    test('reads bmp dimensions and ignores negative top-down height', () {
      final bmp = Uint8List(26)
        ..[0] = 0x42
        ..[1] = 0x4D;
      bmp.buffer.asByteData().setInt32(18, 800, Endian.little);
      bmp.buffer.asByteData().setInt32(22, -600, Endian.little);
      expect(intrinsicImageSize(bmp), (800, 600));
    });

    test('reads jpeg dimensions from the start-of-frame marker', () {
      final jpeg = Uint8List.fromList([
        0xFF, 0xD8, // SOI
        0xFF, 0xE0, 0x00, 0x10, // APP0, length 16
        ...List.filled(14, 0),
        0xFF, 0xC0, 0x00, 0x11, // SOF0, length 17
        0x08, // precision
        0x01, 0x2C, // height 300
        0x01, 0x90, // width 400
        0x03,
      ]);
      expect(intrinsicImageSize(jpeg), (400, 300));
    });

    test('reads webp VP8X dimensions', () {
      final webp = Uint8List(30);
      webp.setRange(0, 4, 'RIFF'.codeUnits);
      webp.setRange(8, 12, 'WEBP'.codeUnits);
      webp.setRange(12, 16, 'VP8X'.codeUnits);
      // 24-bit little-endian, stored minus one: 320x200
      webp.setRange(24, 27, [0x3F, 0x01, 0x00]);
      webp.setRange(27, 30, [0xC7, 0x00, 0x00]);
      expect(intrinsicImageSize(webp), (320, 200));
    });

    test('returns null for junk and truncated payloads', () {
      expect(intrinsicImageSize(Uint8List(0)), isNull);
      expect(intrinsicImageSize(Uint8List.fromList('hello'.codeUnits)), isNull);
      expect(intrinsicImageSize(Uint8List.fromList([0x89, 0x50])), isNull);
      // PNG signature alone without the IHDR fields.
      expect(
        intrinsicImageSize(Uint8List.fromList([0x89, 0x50, 0x4E, 0x47])),
        isNull,
      );
    });
  });
}
