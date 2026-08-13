import 'package:devinorium_frontend/api/sse_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseSseBlock', () {
    test('returns null for empty block', () {
      expect(parseSseBlock(''), isNull);
    });

    test('parses event and data lines', () {
      final event = parseSseBlock('event: message\ndata: hello\ndata: world');
      expect(event, isNotNull);
      expect(event!.event, 'message');
      expect(event.data, 'hello\nworld');
    });

    test('strips single leading space from data', () {
      final event = parseSseBlock('event: done\ndata:  {"ok": true}');
      expect(event!.data, ' {"ok": true}');
    });

    test('ignores unknown lines', () {
      final event = parseSseBlock('event: error\n: comment\ndata: bad');
      expect(event!.event, 'error');
      expect(event.data, 'bad');
    });
  });
}
