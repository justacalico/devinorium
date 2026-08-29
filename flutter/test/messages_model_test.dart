import 'package:devinorium_frontend/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Message truncation fields', () {
    test('parses turn, seq and truncation fields', () {
      final m = Message.fromJson({
        'id': 1,
        'role': 'assistant',
        'content': 'hello',
        'turn_id': 5,
        'seq': 12,
        'truncated': true,
        'total_chars': 1000,
        'truncated_at': 200,
      });
      expect(m.turnId, 5);
      expect(m.seq, 12);
      expect(m.truncated, isTrue);
      expect(m.totalChars, 1000);
      expect(m.truncatedAt, 200);
    });

    test('defaults truncated to false and others to null', () {
      final m = Message.fromJson({'role': 'user', 'content': 'hi'});
      expect(m.truncated, isFalse);
      expect(m.turnId, isNull);
      expect(m.seq, isNull);
      expect(m.totalChars, isNull);
      expect(m.truncatedAt, isNull);
    });

    test('copyWith updates truncation fields', () {
      final m = Message(
        role: 'assistant',
        content: 'hi',
        turnId: 1,
        seq: 2,
        truncated: true,
        totalChars: 100,
      );
      final updated = m.copyWith(
        content: 'full',
        truncated: false,
        totalChars: 200,
      );
      expect(updated.content, 'full');
      expect(updated.truncated, isFalse);
      expect(updated.totalChars, 200);
      expect(updated.turnId, 1);
      expect(updated.seq, 2);
    });

    test('equality and hashCode include truncation fields', () {
      final a = Message(
        id: 1,
        role: 'assistant',
        content: 'hi',
        truncated: true,
        totalChars: 100,
      );
      final b = Message(
        id: 1,
        role: 'assistant',
        content: 'hi',
        truncated: true,
        totalChars: 100,
      );
      final c = Message(
        id: 1,
        role: 'assistant',
        content: 'hi',
        truncated: false,
        totalChars: 100,
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a == c, isFalse);
    });
  });

  group('MessagePage', () {
    test('parses turn-windowed response', () {
      final page = MessagePage.fromJson({
        'messages': [
          {'id': 1, 'role': 'user', 'content': 'hello'},
        ],
        'total': 10,
        'turn_limit': 50,
        'raw_count': 1,
        'before_cursor': 'c1',
        'has_more': true,
      });
      expect(page.messages, hasLength(1));
      expect(page.total, 10);
      expect(page.turnLimit, 50);
      expect(page.rawCount, 1);
      expect(page.beforeCursor, 'c1');
      expect(page.hasMore, isTrue);
    });

    test('defaults missing fields to safe values', () {
      final page = MessagePage.fromJson({
        'messages': [],
      });
      expect(page.messages, isEmpty);
      expect(page.total, 0);
      expect(page.turnLimit, isNull);
      expect(page.rawCount, isNull);
      expect(page.beforeCursor, isNull);
      expect(page.hasMore, isNull);
    });

    test('copyWith updates page fields', () {
      const page = MessagePage(
        messages: [],
        total: 0,
      );
      final updated = page.copyWith(
        messages: [Message(role: 'user', content: 'hi')],
        total: 1,
        beforeCursor: 'c1',
        hasMore: false,
      );
      expect(updated.messages, hasLength(1));
      expect(updated.total, 1);
      expect(updated.beforeCursor, 'c1');
      expect(updated.hasMore, isFalse);
    });

    test('equality and hashCode compare messages and pagination fields', () {
      final a = MessagePage.fromJson({
        'messages': [{'id': 1, 'role': 'user', 'content': 'hello'}],
        'total': 1,
        'turn_limit': 50,
      });
      final b = MessagePage.fromJson({
        'messages': [{'id': 1, 'role': 'user', 'content': 'hello'}],
        'total': 1,
        'turn_limit': 50,
      });
      final c = MessagePage.fromJson({
        'messages': [{'id': 1, 'role': 'user', 'content': 'hello'}],
        'total': 1,
        'turn_limit': 25,
      });
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a == c, isFalse);
    });
  });
}
