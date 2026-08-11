import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:http/browser_client.dart';
import 'package:web/web.dart' as web;

import 'api_client.dart';
import '../models/models.dart' show tryDecodeJson;

/// Reads a streaming Server-Sent Events response from the backend's
/// `/api/threads/:id/send/stream` endpoint using the browser's Fetch API.
///
/// We can't use the `http` package here because it doesn't expose streaming
/// response bodies on web. Instead we build a `FormData` object (so the
/// browser sets its own multipart boundary) and call `window.fetch` directly
/// with `credentials: 'include'` so the HttpOnly session cookie is sent.
///
/// A single `TextDecoder` with `stream: true` is used so multi-byte UTF-8
/// characters that are split across `fetch` chunks decode correctly.
Stream<SseEvent> fetchSseStream({
  required BrowserClient client,
  required String path,
  required String prompt,
  required List<({String filename, String mime, Uint8List bytes})> attachments,
}) {
  // Cancels the underlying fetch when the stream subscription is canceled,
  // e.g. when the user sends a new message before the previous one finishes.
  final abort = web.AbortController();
  final controller = StreamController<SseEvent>(
    onCancel: () {
      try {
        abort.abort();
      } catch (_) {}
    },
  );
  _runSse(
    controller: controller,
    abort: abort,
    path: path,
    prompt: prompt,
    attachments: attachments,
  );
  return controller.stream;
}

Future<void> _runSse({
  required StreamController<SseEvent> controller,
  required web.AbortController abort,
  required String path,
  required String prompt,
  required List<({String filename, String mime, Uint8List bytes})> attachments,
}) async {
  web.ReadableStreamDefaultReader? reader;
  try {
    final form = web.FormData();
    form.append('prompt', prompt.toJS);
    for (final a in attachments) {
      final blob = web.Blob(
        [a.bytes.toJS].toJS,
        web.BlobPropertyBag(type: a.mime),
      );
      form.append('file', blob, a.filename);
    }

    final init = web.RequestInit(
      method: 'POST',
      body: form,
      credentials: 'include',
      signal: abort.signal,
    );

    final response = await web.window.fetch(path.toJS, init).toDart;

    if (response.status >= 400) {
      final text = (await response.text().toDart).toDart;
      final err = tryDecodeJson(text);
      throw ApiException(
        err != null && err['error'] is String
            ? err['error'] as String
            : (text.isNotEmpty ? 'HTTP ${response.status}: $text' : 'HTTP ${response.status}'),
        response.status,
      );
    }

    final body = response.body;
    if (body == null) throw ApiException('no response body', response.status);
    reader = web.ReadableStreamDefaultReader(body);

    // Reuse one TextDecoder with streaming=true so characters split across
    // `reader.read()` chunks still decode correctly.
    final decoder = web.TextDecoder(
      'utf-8',
      web.TextDecoderOptions(fatal: false),
    );

    String buffer = '';
    while (true) {
      final result = await reader.read().toDart;
      if (result.done) {
        // Flush any remaining decoder state.
        buffer += decoder.decode();
        break;
      }
      final value = result.value;
      if (value == null) continue;
      if (!value.typeofEquals('object')) {
        throw ApiException('Unexpected stream chunk type', 0);
      }
      buffer += decoder.decode(
        value as JSObject,
        web.TextDecodeOptions(stream: true),
      );

      while (true) {
        final idx = buffer.indexOf('\n\n');
        if (idx < 0) break;
        final block = buffer.substring(0, idx);
        buffer = buffer.substring(idx + 2);
        final event = _parseSseBlock(block);
        if (event != null && !controller.isClosed) controller.add(event);
      }
    }

    final tail = buffer.trim();
    if (tail.isNotEmpty && !controller.isClosed) {
      final event = _parseSseBlock(tail);
      if (event != null) controller.add(event);
    }
  } catch (e) {
    // Don't surface errors after the listener has gone (e.g. after cancel).
    if (!controller.isClosed && controller.hasListener) {
      try {
        controller.addError(e is ApiException ? e : ApiException('$e', 0));
      } catch (_) {
        // Controller may close between the check and addError; ignore.
      }
    }
  } finally {
    if (reader != null) {
      try {
        await reader.cancel().toDart;
      } catch (_) {}
    }
    if (!controller.isClosed) controller.close();
  }
}

SseEvent? _parseSseBlock(String block) {
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
  // Ignore blocks with no event name — the backend only emits named events
  // (user_message, chunk, done, error) and comments (: ...), which we skip.
  if (event.isEmpty) return null;
  return SseEvent(event, dataLines.join('\n'));
}
