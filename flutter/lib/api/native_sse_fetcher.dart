import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../l10n/global_l10n.dart';
import '../models/models.dart';
import 'api_types.dart';
import 'sse_parser.dart';

const _maxEventBytes = 4 * 1024 * 1024;

Stream<SseEvent> nativeSseStream({
  required http.Client Function() clientFactory,
  required String baseUrl,
  required String token,
  required String path,
  String method = 'POST',
  Map<String, String>? fields,
  List<({String filename, String mime, Uint8List bytes})>? attachments,
}) {
  if (baseUrl.isEmpty) {
    return Stream.error(ApiException(appL10n.serverUrlNotConfigured, 0));
  }
  if (token.isEmpty) {
    return Stream.error(ApiException(appL10n.authenticationTokenNotSet, 0));
  }

  final base = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
  final uri = Uri.parse('$base$path');
  late final http.BaseRequest req;
  if (method == 'GET') {
    req = http.Request('GET', uri);
  } else {
    final multipart = http.MultipartRequest('POST', uri);
    if (fields != null) multipart.fields.addAll(fields);
    for (final a in attachments ?? []) {
      multipart.files.add(http.MultipartFile.fromBytes(
        'file',
        a.bytes,
        filename: a.filename,
        contentType: http.MediaType.parse(a.mime),
      ));
    }
    req = multipart;
  }
  req.headers['Authorization'] = 'Bearer $token';

  // Created on first listen so the config checks above can fail without
  // leaking one, and so an unlistened stream fires no request at all.
  http.Client? client;
  var clientClosed = false;
  void closeClient() {
    if (clientClosed) return;
    clientClosed = true;
    try {
      client?.close();
    } catch (_) {}
  }

  late final StreamController<SseEvent> controller;
  controller = StreamController<SseEvent>(
    onListen: () {
      client = clientFactory();
      _run(client!, req, controller, onDone: closeClient);
    },
    onCancel: closeClient,
  );

  return controller.stream;
}

Future<void> _run(
  http.Client client,
  http.BaseRequest req,
  StreamController<SseEvent> controller, {
  required void Function() onDone,
}) async {
  try {
    final streamed = await client.send(req);
    if (streamed.statusCode >= 400) {
      final body = await streamed.stream.bytesToString();
      final err = tryDecodeJson(body);
      controller.addError(ApiException(
        err != null && err['error'] is String
            ? err['error'] as String
            : sanitizeHttpErrorBody(
                body,
                appL10n.httpErrorStatus(streamed.statusCode),
              ),
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
      // Only the unterminated tail counts toward the cap: a chunk can carry
      // many complete events.
      if (buffer.length > _maxEventBytes) {
        throw ApiException('SSE event exceeded ${_maxEventBytes}B', 0);
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
    onDone();
  }
}
