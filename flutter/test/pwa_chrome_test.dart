import 'package:devinorium_frontend/services/pwa_chrome.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('colorToHex', () {
    test('formats RGB channels as uppercase hex', () {
      expect(colorToHex(const Color(0xFF0A0A0A)), '#0A0A0A');
      expect(colorToHex(const Color(0xFFFFFBFE)), '#FFFBFE');
      expect(colorToHex(Colors.black), '#000000');
      expect(colorToHex(Colors.white), '#FFFFFF');
    });

    test('drops the alpha channel', () {
      expect(colorToHex(const Color(0x80123456)), '#123456');
      expect(colorToHex(Colors.transparent), '#000000');
    });
  });

  group('syncPwaChrome', () {
    test('is a no-op off the web', () {
      syncPwaChrome(const Color(0xFF0A0A0A), true);
      syncPwaChrome(const Color(0xFFFFFBFE), false);
    });
  });
}
