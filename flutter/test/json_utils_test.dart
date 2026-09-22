import 'package:devinorium_frontend/models/json_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('sanitizeHttpErrorBody', () {
    test('returns fallback for empty body', () {
      expect(sanitizeHttpErrorBody('', 'HTTP 500'), 'HTTP 500');
      expect(sanitizeHttpErrorBody('   \n  ', 'HTTP 500'), 'HTTP 500');
    });

    test('returns fallback for html and proxy pages', () {
      expect(
        sanitizeHttpErrorBody('<html><body>Bad Gateway</body></html>', 'HTTP 502'),
        'HTTP 502',
      );
      expect(
        sanitizeHttpErrorBody('  \n<!DOCTYPE html><title>x</title>', 'HTTP 502'),
        'HTTP 502',
      );
    });

    test('truncates long bodies', () {
      final long = 'x' * 500;
      final out = sanitizeHttpErrorBody(long, 'HTTP 500');
      expect(out.length, 301);
      expect(out, '${'x' * 300}…');
    });

    test('keeps short plain text trimmed', () {
      expect(sanitizeHttpErrorBody('  something broke\n', 'HTTP 500'), 'something broke');
      expect(sanitizeHttpErrorBody('a' * 300, 'HTTP 500'), 'a' * 300);
    });
  });
}
