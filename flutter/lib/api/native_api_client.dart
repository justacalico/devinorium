import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/global_l10n.dart';
import '../models/models.dart';
import 'api_client.dart';
import 'native_sse_fetcher.dart';

/// API client for native (desktop/mobile) builds.
///
/// Reads the server URL and bearer token from [SharedPreferences] and attaches
/// an `Authorization: Bearer <token>` header to every request.
class NativeApiClient implements BaseApiClient {
  final http.Client _client;

  String _baseUrl = '';
  String _token = '';
  String _username = '';
  bool _loaded = false;

  NativeApiClient({http.Client? client}) : _client = client ?? http.Client();

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    _baseUrl = (prefs.getString('devinorium_server_url') ?? '').trim();
    _token = prefs.getString('devinorium_token') ?? '';
    _username = prefs.getString('devinorium_username') ?? '';
    _loaded = true;
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('devinorium_server_url', _baseUrl);
    await prefs.setString('devinorium_token', _token);
    await prefs.setString('devinorium_username', _username);
  }

  Uri _url(String path) {
    if (_baseUrl.isEmpty) {
      throw ApiException(appL10n.serverUrlNotConfigured, 401);
    }
    final base = _baseUrl.endsWith('/') ? _baseUrl.substring(0, _baseUrl.length - 1) : _baseUrl;
    return Uri.parse('$base$path');
  }

  Map<String, String> get _headers {
    final h = <String, String>{
      'Accept': 'application/json',
    };
    if (_token.isNotEmpty) {
      h['Authorization'] = 'Bearer $_token';
    }
    return h;
  }

  @override
  Future<bool> get isConfigured async {
    await _ensureLoaded();
    return _baseUrl.isNotEmpty && _token.isNotEmpty;
  }

  @override
  Future<void> setServerUrl(String serverUrl) async {
    _baseUrl = serverUrl.trim();
    await _save();
  }

  @override
  Future<void> setToken(String token) async {
    _token = token.trim();
    await _save();
  }

  @override
  Future<void> setUsername(String username) async {
    _username = username.trim();
    await _save();
  }

  @override
  Future<void> clearCredentials() async {
    _baseUrl = '';
    _token = '';
    _username = '';
    _loaded = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('devinorium_server_url');
    await prefs.remove('devinorium_token');
    await prefs.remove('devinorium_username');
  }

  Future<String> get username async {
    await _ensureLoaded();
    return _username;
  }

  Future<Map<String, dynamic>> _json(
    String method,
    String path,
    Object? body,
  ) async {
    await _ensureLoaded();
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
        throw ApiException(err['error'] as String, resp.statusCode);
      }
      if (text.isNotEmpty) {
        throw ApiException(text, resp.statusCode);
      }
      throw ApiException(appL10n.httpErrorStatus(resp.statusCode), resp.statusCode);
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
  Future<Map<String, dynamic>> patch(String path, [Object? body]) =>
      _json('PATCH', path, body);

  @override
  Future<Map<String, dynamic>> delete(String path) => _json('DELETE', path, null);

  @override
  Future<List<Map<String, dynamic>>> getList(String path) async {
    await _ensureLoaded();
    final req = http.Request('GET', _url(path));
    req.headers.addAll(_headers);
    final streamed = await _client.send(req);
    final resp = await http.Response.fromStream(streamed);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      final err = tryDecodeJson(resp.body);
      throw ApiException(
        err != null && err['error'] is String
            ? err['error'] as String
            : (resp.body.isNotEmpty ? resp.body : appL10n.httpErrorStatus(resp.statusCode)),
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
    await _ensureLoaded();
    final req = http.MultipartRequest('POST', _url(path));
    req.headers.addAll(_headers);
    req.fields.addAll(fields);
    for (final f in files) {
      req.files.add(http.MultipartFile.fromBytes(
        'file',
        f.bytes,
        filename: f.filename,
        contentType: http.MediaType.parse(f.mime),
      ));
    }
    final streamed = await _client.send(req);
    final resp = await http.Response.fromStream(streamed);
    return _parse(resp);
  }

  @override
  Stream<SseEvent> sendStream({
    required String path,
    required String prompt,
    List<({String filename, String mime, Uint8List bytes})> attachments =
        const [],
  }) {
    return nativeSseStream(
      client: http.Client(),
      baseUrl: _baseUrl,
      token: _token,
      path: path,
      method: 'POST',
      fields: {'prompt': prompt},
      attachments: attachments,
    );
  }

  @override
  Stream<SseEvent> getStream({
    required String path,
  }) {
    return nativeSseStream(
      client: http.Client(),
      baseUrl: _baseUrl,
      token: _token,
      path: path,
      method: 'GET',
    );
  }

  @override
  Future<void> init() => _ensureLoaded();

  @override
  bool get isNative => true;

  @override
  Future<String?> get serverUrl async {
    await _ensureLoaded();
    return _baseUrl.isNotEmpty ? _baseUrl : null;
  }
}
