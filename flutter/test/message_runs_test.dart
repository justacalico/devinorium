import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/utils/message_runs.dart';
import 'package:flutter_test/flutter_test.dart';

MessagePart _text(String content) => MessagePart.text(content: content);
MessagePart _thinking(String content) => MessagePart.thinking(content: content);
MessagePart _tool(
  String id, {
  String kind = 'read',
  String status = 'completed',
  String? title,
}) => MessagePart.toolCall(
  toolCall: ToolCallData(
    id: id,
    title: title ?? 'tool $id',
    kind: kind,
    status: status,
  ),
);

void main() {
  group('buildMessageRuns', () {
    test('empty parts produce no rows', () {
      expect(buildMessageRuns(const []), isEmpty);
    });

    test('token fragments merge into one text run', () {
      final rows = buildMessageRuns([
        _text('Hello'),
        _text(', let me look'),
        _text(' at this repo.'),
      ]);
      expect(rows, hasLength(1));
      final run = rows.single as TextRun;
      expect(run.text, 'Hello, let me look at this repo.');
    });

    test('utterance boundaries insert a paragraph break', () {
      final rows = buildMessageRuns([
        _thinking('Hello, let me look at this repo.'),
        _thinking('Alright now I know it.'),
        _thinking('Let me do the change.'),
        _thinking('Done'),
      ]);
      expect(rows, hasLength(1));
      final run = rows.single as ThinkingRun;
      expect(
        run.text,
        'Hello, let me look at this repo.\n\n'
        'Alright now I know it.\n\n'
        'Let me do the change.\n\nDone',
      );
    });

    test('text runs merge raw even at sentence boundaries', () {
      final rows = buildMessageRuns([
        _text('1. First item\n2.'),
        _text(' Second item'),
      ]);
      final run = rows.single as TextRun;
      expect(run.text, '1. First item\n2. Second item');
    });

    test('whitespace-only parts of the other kind do not split a run', () {
      final rows = buildMessageRuns([
        _text('a'),
        _thinking(' '),
        _text('b'),
        _thinking('x'),
        _text(' \n'),
        _thinking('y'),
      ]);
      expect(rows.map((r) => r.runtimeType).toList(), [TextRun, ThinkingRun]);
      expect((rows[0] as TextRun).text, 'ab');
      expect((rows[1] as ThinkingRun).text, 'xy');
    });

    test('whitespace-only parts never open a run or break a streak', () {
      final rows = buildMessageRuns([
        _text('   '),
        _tool('a'),
        _tool('b'),
        _thinking(' \n '),
        _tool('c'),
        _text('done'),
      ]);
      expect(rows.map((r) => r.runtimeType).toList(), [ToolGroupRun, TextRun]);
      expect((rows.first as ToolGroupRun).tools, hasLength(3));
    });

    test('thinking runs split around tool calls', () {
      final rows = buildMessageRuns([
        _thinking('Let me look.'),
        _tool('t1'),
        _thinking('Now I know.'),
        _tool('t2'),
        _thinking('Done.'),
      ]);
      expect(rows.map((r) => r.runtimeType).toList(), [
        ThinkingRun,
        ToolRun,
        ThinkingRun,
        ToolRun,
        ThinkingRun,
      ]);
    });

    test('text, tool, text ordering is preserved', () {
      final rows = buildMessageRuns([
        _text('before'),
        _tool('t1', kind: 'execute'),
        _text('after'),
      ]);
      expect(rows, hasLength(3));
      expect(rows[0], isA<TextRun>());
      expect((rows[1] as ToolRun).tool.id, 't1');
      expect((rows[2] as TextRun).text, 'after');
    });

    test('alternating text and thinking stay separate', () {
      final rows = buildMessageRuns([
        _thinking('planning'),
        _text('answer'),
        _thinking('more planning'),
        _text('more answer'),
      ]);
      expect(rows.map((r) => r.runtimeType).toList(), [
        ThinkingRun,
        TextRun,
        ThinkingRun,
        TextRun,
      ]);
    });

    test('empty content parts are skipped', () {
      final rows = buildMessageRuns([_text(''), _thinking(''), _text('real')]);
      expect(rows, hasLength(1));
      expect((rows.single as TextRun).text, 'real');
    });

    test('finished tool streaks collapse into a group', () {
      final rows = buildMessageRuns([
        _tool('a'),
        _tool('b'),
        _tool('c', status: 'failed'),
      ]);
      expect(rows, hasLength(1));
      final group = rows.single as ToolGroupRun;
      expect(group.tools.map((t) => t.id), ['a', 'b', 'c']);
      expect(group.id, 'group:tool:0:a');
    });

    test('a single tool stays an individual row', () {
      final rows = buildMessageRuns([_tool('only')]);
      expect(rows.single, isA<ToolRun>());
    });

    test('in-progress tools keep a streak expanded', () {
      final rows = buildMessageRuns([
        _tool('a'),
        _tool('b', status: 'in_progress'),
        _tool('c'),
      ]);
      expect(rows, hasLength(3));
      expect(rows.every((r) => r is ToolRun), isTrue);
    });

    test('a running tail stays expanded while the finished prefix groups', () {
      final rows = buildMessageRuns([
        _tool('a'),
        _tool('b'),
        _tool('c', status: 'in_progress'),
      ]);
      expect(rows.map((r) => r.runtimeType).toList(), [ToolGroupRun, ToolRun]);
      expect((rows.first as ToolGroupRun).tools.map((t) => t.id), ['a', 'b']);
      expect((rows.last as ToolRun).tool.id, 'c');
    });

    test('group keeps its id as the running tail completes', () {
      final streaming = buildMessageRuns([
        _tool('a'),
        _tool('b'),
        _tool('c', status: 'in_progress'),
      ]);
      final done = buildMessageRuns([_tool('a'), _tool('b'), _tool('c')]);
      expect(streaming.first, isA<ToolGroupRun>());
      expect(done.single, isA<ToolGroupRun>());
      expect(streaming.first.id, done.single.id);
      expect((done.single as ToolGroupRun).tools, hasLength(3));
    });

    test('tool streaks separated by text group independently', () {
      final rows = buildMessageRuns([
        _tool('a'),
        _tool('b'),
        _text('middle'),
        _tool('c'),
        _tool('d'),
      ]);
      expect(rows.map((r) => r.runtimeType).toList(), [
        ToolGroupRun,
        TextRun,
        ToolGroupRun,
      ]);
      expect((rows[0] as ToolGroupRun).tools, hasLength(2));
      expect((rows[2] as ToolGroupRun).tools, hasLength(2));
    });

    test('run ids are stable while appending parts', () {
      final first = buildMessageRuns([_thinking('Hello.'), _tool('t1')]);
      final second = buildMessageRuns([
        _thinking('Hello.'),
        _tool('t1'),
        _thinking('World.'),
      ]);
      expect(second[0].id, first[0].id);
      expect(second[1].id, first[1].id);
      expect(second[2].id, isNot(first[0].id));
    });
  });

  group('startsNewUtterance', () {
    test('sentence end plus uppercase start splits', () {
      expect(startsNewUtterance('Done.', 'Next step'), isTrue);
      expect(startsNewUtterance('Done. ', ' Next step'), isTrue);
      expect(startsNewUtterance('Really?', 'Yes'), isTrue);
    });

    test('fragments do not split', () {
      expect(startsNewUtterance('Hello', ' world'), isFalse);
      expect(startsNewUtterance('end.', ' lowercase continuation'), isFalse);
      expect(startsNewUtterance('version 3.', '2 released'), isFalse);
      expect(startsNewUtterance('', 'Start'), isFalse);
      expect(startsNewUtterance('Done.', ''), isFalse);
    });

    test('plan markup fragments never split', () {
      expect(
        startsNewUtterance('done.', '<update_plan><step>x</step>'),
        isFalse,
      );
    });
  });

  group('toolGroupCounts', () {
    test('buckets kinds into summary groups', () {
      final tools = [
        ToolCallData(id: '1', title: 'a', kind: 'read', status: 'completed'),
        ToolCallData(id: '2', title: 'b', kind: 'read', status: 'completed'),
        ToolCallData(id: '3', title: 'c', kind: 'edit', status: 'completed'),
        ToolCallData(id: '4', title: 'd', kind: 'delete', status: 'completed'),
        ToolCallData(id: '5', title: 'e', kind: 'execute', status: 'completed'),
        ToolCallData(id: '6', title: 'f', kind: 'search', status: 'completed'),
        ToolCallData(id: '7', title: 'g', kind: 'think', status: 'completed'),
      ];
      final c = toolGroupCounts(tools);
      expect(c.reads, 2);
      expect(c.edits, 2);
      expect(c.commands, 1);
      expect(c.searches, 1);
      expect(c.others, 1);
    });
  });
}
