import 'dart:convert';
import 'dart:typed_data';

import 'package:http/browser_client.dart';
import 'package:http/http.dart' as http;

import '../models/models.dart';
import 'sse_fetcher.dart';

/// Thin wrapper around [http] that:
/// - Uses [BrowserClient] with `withCredentials = true` so the HttpOnly
///   session cookie is sent automatically by the browser on every request
///   (same-origin). The cookie itself is never visible to Dart/JS.
/// - Normalizes errors into a human-readable [String].
///
/// All paths are relative (e.g. "/api/threads") and resolve against the same
/// origin that served the Flutter app, so CORS/CSRF Origin checks pass.
class ApiClient {
  static final ApiClient _instance = ApiClient._();
  factory ApiClient() => _instance;

  late final BrowserClient _client;

  ApiClient._() {
    _client = BrowserClient()..withCredentials = true;
  }

  Future<Map<String, dynamic>> get(String path) async =>
      _json('GET', path, null);

  Future<Map<String, dynamic>> post(String path, [Object? body]) async =>
      _json('POST', path, body);

  Future<Map<String, dynamic>> patch(String path, [Object? body]) async =>
      _json('PATCH', path, body);

  Future<Map<String, dynamic>> delete(String path) async =>
      _json('DELETE', path, null);

  Future<Map<String, dynamic>> _json(
    String method,
    String path,
    Object? body,
  ) async {
    final uri = Uri.parse(path);
    http.Request req = http.Request(method, uri);
    if (body != null) {
      req.headers['content-type'] = 'application/json; charset=utf-8';
      req.body = jsonEncode(body);
    }
    final streamed = await _client.send(req);
    final resp = await http.Response.fromStream(streamed);
    return _parse(resp);
  }

  Future<Map<String, dynamic>> _parse(http.Response resp) async {
    final text = resp.body;
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      final err = tryDecodeJson(text);
      if (err != null && err['error'] is String) {
        throw ApiException(err['error'] as String, resp.statusCode);
      }
      if (text.isNotEmpty) {
        throw ApiException(text, resp.statusCode);
      }
      throw ApiException('HTTP ${resp.statusCode}', resp.statusCode);
    }
    if (text.isEmpty) return <String, dynamic>{};
    final decoded = jsonDecode(text);
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is List) return {'_list': decoded};
    throw ApiException('unexpected response shape', resp.statusCode);
  }

  /// GET that returns a list. The backend returns a bare JSON array.
  Future<List<Map<String, dynamic>>> getList(String path) async {
    final uri = Uri.parse(path);
    final req = http.Request('GET', uri);
    final streamed = await _client.send(req);
    final resp = await http.Response.fromStream(streamed);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      final err = tryDecodeJson(resp.body);
      throw ApiException(
        err != null && err['error'] is String
            ? err['error'] as String
            : (resp.body.isNotEmpty ? resp.body : 'HTTP ${resp.statusCode}'),
        resp.statusCode,
      );
    }
    final decoded = jsonDecode(resp.body);
    if (decoded is List) {
      return decoded.cast<Map<String, dynamic>>();
    }
    throw ApiException('expected a list', resp.statusCode);
  }

  /// Upload files via multipart POST to [path]. [fields] are form text fields.
  /// Returns the parsed JSON body.
  Future<Map<String, dynamic>> uploadMultipart(
    String path,
    Map<String, String> fields,
    List<({String filename, String mime, Uint8List bytes})> files,
  ) async {
    final uri = Uri.parse(path);
    final req = http.MultipartRequest('POST', uri);
    req.headers.addAll({'Accept': 'application/json'});
    req.fields.addAll(fields);
    for (final f in files) {
      req.files.add(http.MultipartFile.fromBytes(
        'file',
        f.bytes,
        filename: f.filename,
      ));
    }
    final streamed = await _client.send(req);
    final resp = await http.Response.fromStream(streamed);
    return _parse(resp);
  }

  /// POST a multipart form with a single text field `prompt` and optional
  /// file attachments, then stream the Server-Sent Events response.
  Stream<SseEvent> sendStream({
    required String path,
    required String prompt,
    List<({String filename, String mime, Uint8List bytes})> attachments =
        const [],
  }) {
    return fetchSseStream(
      client: _client,
      path: path,
      prompt: prompt,
      attachments: attachments,
    );
  }
}

class ApiException implements Exception {
  final String message;
  final int statusCode;
  ApiException(this.message, this.statusCode);
  @override
  String toString() => message;
}

/// A single parsed SSE event from the streaming send endpoint.
class SseEvent {
  final String event;
  final String data;
  SseEvent(this.event, this.data);
}
