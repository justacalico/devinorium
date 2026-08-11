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
Stream<SseEvent> fetchSseStream({
  required BrowserClient client,
  required String path,
  required String prompt,
  required List<({String filename, String mime, Uint8List bytes})> attachments,
}) {
  final controller = StreamController<SseEvent>();
  _runSse(
    controller: controller,
    path: path,
    prompt: prompt,
    attachments: attachments,
  );
  return controller.stream;
}

Future<void> _runSse({
  required StreamController<SseEvent> controller,
  required String path,
  required String prompt,
  required List<({String filename, String mime, Uint8List bytes})> attachments,
}) async {
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
    final reader = web.ReadableStreamDefaultReader(body);

    String buffer = '';
    while (true) {
      final result = await reader.read().toDart;
      if (result.done) break;
      final value = result.value;
      if (value == null) continue;
      buffer += _decodeUtf8(value);

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
    if (!controller.isClosed) {
      controller.addError(e is ApiException ? e : ApiException('$e', 0));
    }
  } finally {
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
  // (user_message, chunk, done, error) and the SSE spec says a missing
  // event: field means the last event type, which we don't track.
  if (event.isEmpty) return null;
  return SseEvent(event, dataLines.join('\n'));
}

/// Decode a JS Uint8Array chunk into a Dart string using TextDecoder.
String _decodeUtf8(JSAny bytes) {
  final decoder = _TextDecoder('utf-8');
  return decoder.decode(bytes).toDart;
}

@JS('TextDecoder')
extension type _TextDecoder._(JSObject _) implements JSObject {
  external factory _TextDecoder([String label]);
  external JSString decode(JSAny? input);
}

// Suppress unused warning for the streams import (kept for clarity).
// ignore: unused_element
final _ = web.ReadableStream;
