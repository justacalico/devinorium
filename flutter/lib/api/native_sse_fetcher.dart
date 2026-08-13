import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/models.dart';
import 'api_types.dart';
import 'sse_parser.dart';

Stream<SseEvent> nativeSseStream({
  required http.Client client,
  required String baseUrl,
  required String token,
  required String path,
  required String prompt,
  List<({String filename, String mime, Uint8List bytes})> attachments =
      const [],
}) {
  if (baseUrl.isEmpty) {
    return Stream.error(ApiException('server URL not configured', 401));
  }
  if (token.isEmpty) {
    return Stream.error(ApiException('authentication token not set', 401));
  }

  final base = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
  final uri = Uri.parse('$base$path');
  final req = http.MultipartRequest('POST', uri);
  req.headers['Authorization'] = 'Bearer $token';
  req.fields['prompt'] = prompt;
  for (final a in attachments) {
    req.files.add(http.MultipartFile.fromBytes(
      'file',
      a.bytes,
      filename: a.filename,
      contentType: http.MediaType.parse(a.mime),
    ));
  }

  final controller = StreamController<SseEvent>(
    onCancel: () {
      client.close();
    },
  );

  _run(client, req, controller);
  return controller.stream;
}

Future<void> _run(
  http.Client client,
  http.MultipartRequest req,
  StreamController<SseEvent> controller,
) async {
  try {
    final streamed = await client.send(req);
    if (streamed.statusCode >= 400) {
      final body = await streamed.stream.bytesToString();
      final err = tryDecodeJson(body);
      controller.addError(ApiException(
        err != null && err['error'] is String
            ? err['error'] as String
            : (body.isNotEmpty ? body : 'HTTP ${streamed.statusCode}'),
        streamed.statusCode,
      ));
      return;
    }

    final buffer = StringBuffer();
    await for (final chunk in streamed.stream.transform(utf8.decoder)) {
      buffer.write(chunk);
      while (true) {
        final text = buffer.toString();
        final idx = text.indexOf('\n\n');
        if (idx < 0) break;
        final block = text.substring(0, idx);
        buffer.clear();
        buffer.write(text.substring(idx + 2));
        final event = parseSseBlock(block);
        if (event != null && !controller.isClosed) {
          controller.add(event);
        }
      }
    }

    final tail = buffer.toString().trim();
    if (tail.isNotEmpty && !controller.isClosed) {
      final event = parseSseBlock(tail);
      if (event != null) controller.add(event);
    }
  } catch (e) {
    if (!controller.isClosed && controller.hasListener) {
      controller.addError(e is ApiException ? e : ApiException('$e', 0));
    }
  } finally {
    if (!controller.isClosed) controller.close();
  }
}
