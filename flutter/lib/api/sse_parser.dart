import 'api_types.dart';

/// Parse a single SSE block (a chunk of text terminated by a double newline).
///
/// Recognises `event:` and `data:` lines. Returns `null` when the block does
/// not contain an event name.
SseEvent? parseSseBlock(String block) {
  String event = '';
  final dataLines = <String>[];
  for (final line in block.split('\n')) {
    if (line.startsWith('event:')) {
      event = line.substring(6).trim();
    } else if (line.startsWith('data:')) {
      final rest = line.substring(5);
      final stripped = rest.startsWith(' ') ? rest.substring(1) : rest;
      dataLines.add(stripped);
    }
  }
  if (event.isEmpty) return null;
  return SseEvent(event, dataLines.join('\n'));
}
