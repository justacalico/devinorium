import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'api_types.dart';

// Conditional import: the web implementation uses package:web and
// dart:js_interop, which are not available in the VM test runner.
import 'sse_fetcher_stub.dart' if (dart.library.js_interop) 'sse_fetcher_web.dart';

/// Reads a streaming Server-Sent Events response from the backend's
/// `/api/threads/:id/send/stream` endpoint.
Stream<SseEvent> fetchSseStream({
  required http.Client client,
  required String path,
  required String prompt,
  required List<({String filename, String mime, Uint8List bytes})> attachments,
}) {
  return platformFetchSseStream(
    client: client,
    path: path,
    prompt: prompt,
    attachments: attachments,
  );
}
