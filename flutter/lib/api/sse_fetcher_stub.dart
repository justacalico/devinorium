import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'api_types.dart';

Stream<SseEvent> platformFetchSseStream({
  required http.Client client,
  required String path,
  required String prompt,
  required List<({String filename, String mime, Uint8List bytes})> attachments,
}) {
  return Stream.error(ApiException('SSE streaming is only supported on the web', 0));
}
