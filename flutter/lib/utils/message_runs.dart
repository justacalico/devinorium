import '../models/models.dart';

/// One visual row derived from a message's ordered parts.
///
/// Providers stream text and thinking as token-sized fragments, so
/// [buildMessageRuns] merges consecutive same-kind fragments into a single run
/// while tool calls always stand alone as their own rows. Consecutive
/// finished tool calls collapse into a [ToolGroupRun] summary.
sealed class MessageRun {
  const MessageRun(this.id);

  /// Stable identity for widget keys across rebuilds.
  final String id;
}

final class TextRun extends MessageRun {
  const TextRun(super.id, this.text);
  final String text;
}

final class ThinkingRun extends MessageRun {
  const ThinkingRun(super.id, this.text);
  final String text;
}

final class ToolRun extends MessageRun {
  const ToolRun(super.id, this.tool);
  final ToolCallData tool;
}

final class ToolGroupRun extends MessageRun {
  const ToolGroupRun(super.id, this.tools);
  final List<ToolCallData> tools;
}

bool toolCallTerminal(ToolCallData tool) =>
    tool.status == 'completed' || tool.status == 'failed';

/// Projects ordered message parts into visual rows.
///
/// Consecutive text parts merge into one [TextRun] and consecutive thinking
/// parts into one [ThinkingRun]; each tool call becomes its own [ToolRun].
/// Thinking is plain text, so when a merged chunk clearly starts a new
/// utterance (buffer ends a sentence, chunk starts like a new one) a blank
/// line is inserted to keep separate narration runs visually distinct. Text
/// parts merge raw so markdown structure is never mutated. The leading
/// finished stretch of a tool streak folds into a [ToolGroupRun] while an
/// in-progress tail stays expanded.
List<MessageRun> buildMessageRuns(List<MessagePart> parts) {
  final rows = <MessageRun>[];
  var runType = '';
  var runStart = 0;
  var lastChar = 0;
  final buf = StringBuffer();

  void flush() {
    if (buf.isEmpty) return;
    final text = buf.toString();
    buf.clear();
    lastChar = 0;
    rows.add(
      runType == 'thinking'
          ? ThinkingRun('thinking:$runStart', text)
          : TextRun('text:$runStart', text),
    );
  }

  for (var i = 0; i < parts.length; i++) {
    final part = parts[i];
    switch (part.type) {
      case 'tool_call':
        flush();
        runType = '';
        final tool = part.toolCall;
        if (tool != null) {
          rows.add(ToolRun('tool:$i:${tool.id}', tool));
        }
      case 'text' || 'thinking':
        final content = part.content ?? '';
        if (content.isEmpty) continue;
        if (content.trim().isEmpty) {
          // Whitespace-only fragments never open a new run; inside a run they
          // are just spacing.
          if (part.type == runType) buf.write(content);
          continue;
        }
        if (part.type != runType) {
          flush();
          runType = part.type;
          runStart = i;
          buf.write(content);
        } else if (runType == 'thinking' &&
            utteranceBreakAfter(lastChar, content)) {
          final trimmed = buf.toString().trimRight();
          buf
            ..clear()
            ..write(trimmed)
            ..write('\n\n')
            ..write(content.trimLeft());
        } else {
          buf.write(content);
        }
        final tail = content.trimRight();
        if (tail.isNotEmpty) lastChar = tail.codeUnitAt(tail.length - 1);
    }
  }
  flush();
  return _groupTools(rows);
}

/// Whether [next] clearly begins a new utterance after [prev]: the buffered
/// text ends a sentence and the chunk starts with an uppercase letter or an
/// opening quote/marker. A leading `<` never counts so plan markup fragments
/// still merge.
bool startsNewUtterance(String prev, String next) {
  final t = prev.trimRight();
  return utteranceBreakAfter(t.isEmpty ? 0 : t.codeUnitAt(t.length - 1), next);
}

/// Char-level form of [startsNewUtterance]; [lastChar] is the last
/// non-whitespace code unit of the preceding text, or 0 when empty.
bool utteranceBreakAfter(int lastChar, String next) {
  const dot = 0x2E, bang = 0x21, question = 0x3F;
  if (lastChar != dot && lastChar != bang && lastChar != question) {
    return false;
  }
  final n = next.trimLeft();
  if (n.isEmpty || n.codeUnitAt(0) == 0x3C) return false;
  final first = n.codeUnitAt(0);
  if (first >= 0x41 && first <= 0x5A) return true;
  const openers = {'"', "'", '`', '(', '*', '#', '-'};
  return openers.contains(n[0]);
}

List<MessageRun> _groupTools(List<MessageRun> rows) {
  final result = <MessageRun>[];
  var i = 0;
  while (i < rows.length) {
    final row = rows[i];
    if (row is! ToolRun) {
      result.add(row);
      i++;
      continue;
    }
    var j = i;
    while (j < rows.length && rows[j] is ToolRun) {
      j++;
    }
    final streak = rows.sublist(i, j).cast<ToolRun>();
    var end = 0;
    while (end < streak.length && toolCallTerminal(streak[end].tool)) {
      end++;
    }
    if (end >= 2) {
      result.add(
        ToolGroupRun(
          'group:${streak.first.id}',
          streak.sublist(0, end).map((r) => r.tool).toList(),
        ),
      );
      result.addAll(streak.sublist(end));
    } else {
      result.addAll(streak);
    }
    i = j;
  }
  return result;
}

/// Per-kind counts for a collapsed tool group summary.
({int reads, int edits, int commands, int searches, int others})
toolGroupCounts(List<ToolCallData> tools) {
  var reads = 0, edits = 0, commands = 0, searches = 0, others = 0;
  for (final tool in tools) {
    switch (tool.kind) {
      case 'read':
        reads++;
      case 'edit' || 'delete' || 'move':
        edits++;
      case 'execute':
        commands++;
      case 'search' || 'fetch':
        searches++;
      default:
        others++;
    }
  }
  return (
    reads: reads,
    edits: edits,
    commands: commands,
    searches: searches,
    others: others,
  );
}
