import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../l10n/global_l10n.dart';
import '../models/models.dart';
import 'api_types.dart';
import 'client_factory_stub.dart'
    if (dart.library.js_interop) 'client_factory_web.dart';
import 'sse_fetcher.dart';

export 'api_types.dart';

/// Common interface for both web and native API clients.
///
/// The web implementation uses HttpOnly cookies, while the native
/// implementation reads the server URL and bearer token from local storage.
abstract class BaseApiClient {
  Future<Map<String, dynamic>> get(String path);
  Future<Map<String, dynamic>> post(String path, [Object? body]);
  Future<Map<String, dynamic>> put(String path, [Object? body]);
  Future<Map<String, dynamic>> patch(String path, [Object? body]);
  Future<Map<String, dynamic>> delete(String path);
  Future<Map<String, dynamic>> deleteWithBody(String path, Object body);
  Future<List<Map<String, dynamic>>> getList(String path);
  Future<Map<String, dynamic>> uploadMultipart(
    String path,
    Map<String, String> fields,
    List<({String filename, String mime, Uint8List bytes})> files,
  );
  Stream<SseEvent> sendStream({
    required String path,
    required String prompt,
    String? mode,
    String? clientMessageId,
    List<({String filename, String mime, Uint8List bytes})> attachments,
  });

  Stream<SseEvent> getStream({required String path});

  /// Whether the client has enough configuration to make requests.
  Future<bool> get isConfigured;

  /// Persist the server URL for native clients (no-op on web).
  Future<void> setServerUrl(String serverUrl);

  /// Persist an authentication token for native clients (no-op on web).
  Future<void> setToken(String token);

  /// Persist the username for display on native clients (no-op on web).
  Future<void> setUsername(String username);

  /// Clear stored credentials on native clients (no-op on web).
  Future<void> clearCredentials();

  /// Ensure local configuration is loaded.
  Future<void> init();

  /// Whether this client is a native bearer-token client.
  bool get isNative;

  /// The configured server URL, if any.
  Future<String?> get serverUrl;

  /// The bearer token for native clients, null on web.
  Future<String?> get token;
}

/// Thin wrapper around [http] that:
/// - Uses [BrowserClient] with `withCredentials = true` so the HttpOnly
///   session cookie is sent automatically by the browser on every request
///   (same-origin). The cookie itself is never visible to Dart/JS.
/// - Normalizes errors into a human-readable [String].
///
/// All paths are relative (e.g. "/api/threads") and resolve against the same
/// origin that served the Flutter app, so CORS/CSRF Origin checks pass.
class ApiClient implements BaseApiClient {
  static ApiClient? _instance;
  factory ApiClient() {
    _instance ??= ApiClient._internal(createClient());
    return _instance!;
  }

  /// Create a client backed by an arbitrary [http.Client]. Used in tests
  /// with a fake client so network calls can be mocked.
  factory ApiClient.withClient(http.Client client) =>
      ApiClient._internal(client);

  final http.Client _client;

  ApiClient._internal(this._client);

  @override
  Future<bool> get isConfigured => Future.value(true);

  @override
  Future<void> setServerUrl(String serverUrl) => Future.value();

  @override
  Future<void> setToken(String token) => Future.value();

  @override
  Future<void> setUsername(String username) => Future.value();

  @override
  Future<void> clearCredentials() => Future.value();

  @override
  Future<void> init() => Future.value();

  @override
  bool get isNative => false;

  @override
  Future<String?> get serverUrl => Future.value(null);

  @override
  Future<String?> get token => Future.value(null);

  @override
  Future<Map<String, dynamic>> get(String path) async =>
      _json('GET', path, null);

  @override
  Future<Map<String, dynamic>> post(String path, [Object? body]) async =>
      _json('POST', path, body);

  @override
  Future<Map<String, dynamic>> put(String path, [Object? body]) async =>
      _json('PUT', path, body);

  @override
  Future<Map<String, dynamic>> patch(String path, [Object? body]) async =>
      _json('PATCH', path, body);

  @override
  Future<Map<String, dynamic>> delete(String path) async =>
      _json('DELETE', path, null);

  @override
  Future<Map<String, dynamic>> deleteWithBody(String path, Object body) async =>
      _json('DELETE', path, body);

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
        throw ApiException(
          err['error'] as String,
          resp.statusCode,
          data: err,
        );
      }
      if (text.isNotEmpty) {
        throw ApiException(text, resp.statusCode);
      }
      throw ApiException(
        appL10n.httpErrorStatus(resp.statusCode),
        resp.statusCode,
      );
    }
    if (text.isEmpty) return <String, dynamic>{};
    final decoded = jsonDecode(text);
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is List) return {'_list': decoded};
    throw ApiException(appL10n.unexpectedResponseShape, resp.statusCode);
  }

  @override
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
            : (resp.body.isNotEmpty
                  ? resp.body
                  : appL10n.httpErrorStatus(resp.statusCode)),
        resp.statusCode,
      );
    }
    final decoded = jsonDecode(resp.body);
    if (decoded is List) {
      return decoded.map((e) => e as Map<String, dynamic>).toList();
    }
    throw ApiException(appL10n.expectedAList, resp.statusCode);
  }

  @override
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
      req.files.add(
        http.MultipartFile.fromBytes(
          'file',
          f.bytes,
          filename: f.filename,
          contentType: http.MediaType.parse(f.mime),
        ),
      );
    }
    final streamed = await _client.send(req);
    final resp = await http.Response.fromStream(streamed);
    return _parse(resp);
  }

  @override
  Stream<SseEvent> sendStream({
    required String path,
    required String prompt,
    String? mode,
    String? clientMessageId,
    List<({String filename, String mime, Uint8List bytes})> attachments =
        const [],
  }) {
    final fields = <String, String>{'prompt': prompt};
    if (mode != null && mode.isNotEmpty) fields['mode'] = mode;
    if (clientMessageId != null && clientMessageId.isNotEmpty) {
      fields['client_message_id'] = clientMessageId;
    }
    return fetchSseStream(
      client: _client,
      path: path,
      method: 'POST',
      fields: fields,
      attachments: attachments,
    );
  }

  @override
  Stream<SseEvent> getStream({required String path}) {
    return fetchSseStream(client: _client, path: path, method: 'GET');
  }
}
