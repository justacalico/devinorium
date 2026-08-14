import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../l10n/global_l10n.dart';
import '../models/models.dart';
import 'api_types.dart';
import 'sse_parser.dart';

Stream<SseEvent> nativeSseStream({
  required http.Client client,
  required String baseUrl,
  required String token,
  required String path,
  String method = 'POST',
  Map<String, String>? fields,
  List<({String filename, String mime, Uint8List bytes})>? attachments,
}) {
  if (baseUrl.isEmpty) {
    return Stream.error(ApiException(appL10n.serverUrlNotConfigured, 401));
  }
  if (token.isEmpty) {
    return Stream.error(ApiException(appL10n.authenticationTokenNotSet, 401));
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

  var clientClosed = false;
  void closeClient() {
    if (clientClosed) return;
    clientClosed = true;
    try {
      client.close();
    } catch (_) {}
  }

  final controller = StreamController<SseEvent>(
    onCancel: closeClient,
  );

  _run(client, req, controller, onDone: closeClient);
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
            : (body.isNotEmpty ? body : appL10n.httpErrorStatus(streamed.statusCode)),
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
    onDone();
  }
}
