import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../l10n/global_l10n.dart';
import '../models/models.dart';
import '../servers/server_profile.dart';
import 'api_client.dart';
import 'native_sse_fetcher.dart';

/// API client for a single native (desktop/mobile) Devinorium server.
///
/// Unlike the old singleton client, this client is constructed from a
/// [ServerProfile] and does not touch [SharedPreferences] directly. The
/// multi-server registry owns persistence; each client only owns its in-memory
/// copy of the profile's URL, token and username.
class NativeApiClient implements BaseApiClient {
  final http.Client _client;

  String _baseUrl = '';
  String _token = '';
  String _username = '';
  ServerProfile? _profile;

  /// Construct an unconfigured client (used only in tests or as a placeholder).
  NativeApiClient({http.Client? client}) : _client = client ?? http.Client();

  @override
  void close() => _client.close();

  /// Construct a client backed by a specific server profile.
  NativeApiClient.fromProfile(
    ServerProfile profile, {
    http.Client? client,
  })  : _client = client ?? http.Client(),
        _profile = profile {
    _baseUrl = profile.baseUrl;
    _token = profile.token;
    _username = profile.username;
  }

  /// The profile this client was created from, if any.
  ServerProfile? get profile => _profile;

  Uri _url(String path) {
    if (_baseUrl.isEmpty) {
      throw ApiException(appL10n.serverUrlNotConfigured, 401);
    }
    final base = _baseUrl.endsWith('/')
        ? _baseUrl.substring(0, _baseUrl.length - 1)
        : _baseUrl;
    return Uri.parse('$base$path');
  }

  Map<String, String> get _headers {
    final h = <String, String>{'Accept': 'application/json'};
    if (_baseUrl.isNotEmpty) {
      final origin = Uri.tryParse(_baseUrl)?.origin;
      if (origin != null && origin.isNotEmpty) {
        h['Origin'] = origin;
      }
    }
    if (_token.isNotEmpty) {
      h['Authorization'] = 'Bearer $_token';
    }
    return h;
  }

  @override
  Future<bool> get isConfigured async {
    return _baseUrl.isNotEmpty && _token.isNotEmpty;
  }

  @override
  Future<void> setServerUrl(String serverUrl) async {
    _baseUrl = serverUrl.trim();
  }

  @override
  Future<void> setToken(String token) async {
    _token = token.trim();
  }

  @override
  Future<void> setUsername(String username) async {
    _username = username.trim();
  }

  @override
  Future<void> clearCredentials() async {
    _baseUrl = '';
    _token = '';
    _username = '';
    _profile = null;
  }

  Future<String> get username async => _username;

  Future<Map<String, dynamic>> _json(
    String method,
    String path,
    Object? body,
  ) async {
    final req = http.Request(method, _url(path));
    req.headers.addAll(_headers);
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
  Future<Map<String, dynamic>> get(String path) => _json('GET', path, null);

  @override
  Future<Map<String, dynamic>> post(String path, [Object? body]) =>
      _json('POST', path, body);

  @override
  Future<Map<String, dynamic>> put(String path, [Object? body]) =>
      _json('PUT', path, body);

  @override
  Future<Map<String, dynamic>> patch(String path, [Object? body]) =>
      _json('PATCH', path, body);

  @override
  Future<Map<String, dynamic>> delete(String path) =>
      _json('DELETE', path, null);

  @override
  Future<Map<String, dynamic>> deleteWithBody(String path, Object body) =>
      _json('DELETE', path, body);

  @override
  Future<List<Map<String, dynamic>>> getList(String path) async {
    final req = http.Request('GET', _url(path));
    req.headers.addAll(_headers);
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
    final req = http.MultipartRequest('POST', _url(path));
    req.headers.addAll(_headers);
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
    List<PathRef> contextPaths = const [],
    List<String> referencedThreadIds = const [],
  }) {
    final fields = <String, String>{'prompt': prompt};
    if (mode != null && mode.isNotEmpty) fields['mode'] = mode;
    if (clientMessageId != null && clientMessageId.isNotEmpty) {
      fields['client_message_id'] = clientMessageId;
    }
    if (contextPaths.isNotEmpty) {
      fields['context_paths'] = jsonEncode([
        for (final r in contextPaths) {'path': r.path, 'is_dir': r.isDir},
      ]);
    }
    if (referencedThreadIds.isNotEmpty) {
      fields['referenced_thread_ids'] = jsonEncode(referencedThreadIds);
    }
    // Each SSE stream uses its own client because nativeSseStream closes it
    // when the stream ends or is cancelled.
    return nativeSseStream(
      client: http.Client(),
      baseUrl: _baseUrl,
      token: _token,
      path: path,
      method: 'POST',
      fields: fields,
      attachments: attachments,
    );
  }

  @override
  Stream<SseEvent> getStream({required String path}) {
    return nativeSseStream(
      client: http.Client(),
      baseUrl: _baseUrl,
      token: _token,
      path: path,
      method: 'GET',
    );
  }

  @override
  Future<void> init() => Future.value();

  @override
  bool get isNative => true;

  @override
  Future<String?> get serverUrl async =>
      _baseUrl.isNotEmpty ? _baseUrl : null;

  @override
  Future<String?> get token async => _token.isNotEmpty ? _token : null;
}
