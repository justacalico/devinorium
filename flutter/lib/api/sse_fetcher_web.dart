import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;

import '../models/models.dart' show tryDecodeJson;
import 'api_types.dart';
import 'sse_parser.dart';

Stream<SseEvent> platformFetchSseStream({
  required http.Client client,
  required String path,
  required String prompt,
  required List<({String filename, String mime, Uint8List bytes})> attachments,
}) {
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

    final decoder = web.TextDecoder(
      'utf-8',
      web.TextDecoderOptions(fatal: false),
    );

    String buffer = '';
    while (true) {
      final result = await reader.read().toDart;
      if (result.done) {
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
        final event = parseSseBlock(block);
        if (event != null && !controller.isClosed) controller.add(event);
      }
    }

    final tail = buffer.trim();
    if (tail.isNotEmpty && !controller.isClosed) {
      final event = parseSseBlock(tail);
      if (event != null) controller.add(event);
    }
  } catch (e) {
    if (!controller.isClosed && controller.hasListener) {
      try {
        controller.addError(e is ApiException ? e : ApiException('$e', 0));
      } catch (_) {}
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
