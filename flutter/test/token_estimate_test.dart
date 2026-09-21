import 'dart:convert';
import 'dart:typed_data';

import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/utils/token_estimate.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _bytes(int n) => Uint8List(n);

/// A minimal PNG header claiming [w]x[h] pixels.
Uint8List _png(int w, int h) {
  final data = Uint8List(33);
  data.setAll(0, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  data.setAll(8, [0, 0, 0, 13]);
  data.setAll(12, [0x49, 0x48, 0x44, 0x52]); // IHDR
  ByteData.sublistView(data, 16, 20).setUint32(0, w);
  ByteData.sublistView(data, 20, 24).setUint32(0, h);
  return data;
}

void main() {
  group('estimateTokens', () {
    test('counts ascii at four per token', () {
      expect(estimateTokens(''), 0);
      expect(estimateTokens('12345678'), 2);
      expect(estimateTokens('123456789'), 3);
    });

    test('counts non-ascii one per character', () {
      expect(estimateTokens('你好世界'), 4);
    });

    test('mixes both rates', () {
      // 6 ascii chars round to 2 tokens; 2 CJK chars are 1 each.
      expect(estimateTokens('hello 你好'), 4);
    });
  });

  group('estimateAttachmentTokens', () {
    test('text attachments scale with content', () {
      final small = estimateAttachmentTokens(
        'a.txt',
        'text/plain',
        _bytes(400),
      );
      final big = estimateAttachmentTokens(
        'a.txt',
        'text/plain',
        _bytes(40000),
      );
      expect(big, greaterThan(small * 50));
    });

    test('binary attachments are a reference only', () {
      final t = estimateAttachmentTokens(
        'blob.bin',
        'application/octet-stream',
        _bytes(1000000),
      );
      expect(t, lessThan(200));
    });

    test('png estimate uses pixel dimensions', () {
      final t = estimateAttachmentTokens(
        'shot.png',
        'image/png',
        _png(800, 600),
      );
      // 800*600/750 = 640 plus wrapper.
      expect(t, greaterThan(600));
      expect(t, lessThan(700));
    });

    test('svg counts as text not image', () {
      final svg = utf8.encode("<svg xmlns='x'><rect width='1'/></svg>");
      final t = estimateAttachmentTokens('icon.svg', 'image/svg+xml', svg);
      expect(t, lessThan(100));
    });

    test('extension marks text even with unknown mime', () {
      final t = estimateAttachmentTokens('main.rs', '', _bytes(4000));
      // ~1000 content tokens plus wrapper.
      expect(t, greaterThan(1000));
    });
  });

  group('estimateDraftTokens', () {
    test('prompt plus overhead and mode suffix', () {
      final bare = estimateDraftTokens(prompt: 'hello', mode: 'ask');
      expect(bare, greaterThan(estimateTokens('hello')));
    });

    test('reference chips add their flat costs', () {
      final base = estimateDraftTokens(prompt: 'hi');
      final withRefs = estimateDraftTokens(
        prompt: 'hi',
        pathRefs: [(path: 'src/main.rs', isDir: false)],
        threadReferences: [const ThreadReference(id: 't2', title: 'Other')],
        machineReferences: [const MachineReference(id: 1, name: 'box')],
      );
      expect(
        withRefs - base,
        pathRefTokens + threadRefTokens + machineRefTokens,
      );
    });

    test('attachments add to the draft', () {
      final base = estimateDraftTokens(prompt: 'fix this');
      final withFile = estimateDraftTokens(
        prompt: 'fix this',
        attachments: [
          (filename: 'log.txt', mime: 'text/plain', bytes: _bytes(4000)),
        ],
      );
      expect(withFile, greaterThan(base + 900));
    });
  });

  group('composeModePrompt', () {
    test('code appends the update_plan suffix', () {
      expect(composeModePrompt('hi', 'code'), contains('update_plan'));
      expect(composeModePrompt('hi', 'code'), startsWith('hi'));
    });

    test('plan prepends the plan instruction', () {
      expect(composeModePrompt('hi', 'plan'), contains('Plan mode'));
      expect(composeModePrompt('hi', 'plan'), endsWith('hi'));
    });

    test('ask prepends the ask instruction', () {
      expect(composeModePrompt('hi', 'ask'), contains('Ask mode'));
    });
  });
}
