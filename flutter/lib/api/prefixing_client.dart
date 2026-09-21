import 'dart:typed_data';

import '../models/models.dart';
import 'api_client.dart';

/// Wraps another [BaseApiClient] and prepends a fixed path prefix to every
/// request path (REST, multipart, and SSE alike).
///
/// Used for federated node access: a node client points at the hub's
/// `/api/federation/nodes/<id>/proxy` prefix so the same credentials and
/// connection serve the satellite's API.
class PrefixingClient implements BaseApiClient {
  PrefixingClient(this._inner, this._prefix);

  final BaseApiClient _inner;
  final String _prefix;

  /// The wrapped client, exposed for unwrapping in type checks.
  BaseApiClient get inner => _inner;

  @override
  String get pathPrefix => _prefix;

  String _p(String path) => '$_prefix$path';

  @override
  Future<Map<String, dynamic>> get(String path) => _inner.get(_p(path));

  @override
  Future<Map<String, dynamic>> post(String path, [Object? body]) =>
      _inner.post(_p(path), body);

  @override
  Future<Map<String, dynamic>> put(String path, [Object? body]) =>
      _inner.put(_p(path), body);

  @override
  Future<Map<String, dynamic>> patch(String path, [Object? body]) =>
      _inner.patch(_p(path), body);

  @override
  Future<Map<String, dynamic>> delete(String path) => _inner.delete(_p(path));

  @override
  Future<Map<String, dynamic>> deleteWithBody(String path, Object body) =>
      _inner.deleteWithBody(_p(path), body);

  @override
  Future<List<Map<String, dynamic>>> getList(String path) =>
      _inner.getList(_p(path));

  @override
  Future<Map<String, dynamic>> uploadMultipart(
    String path,
    Map<String, String> fields,
    List<({String filename, String mime, Uint8List bytes})> files,
  ) =>
      _inner.uploadMultipart(_p(path), fields, files);

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
    List<int> machineIds = const [],
  }) =>
      _inner.sendStream(
        path: _p(path),
        prompt: prompt,
        mode: mode,
        clientMessageId: clientMessageId,
        attachments: attachments,
        contextPaths: contextPaths,
        referencedThreadIds: referencedThreadIds,
        machineIds: machineIds,
      );

  @override
  Stream<SseEvent> postStream({
    required String path,
    Map<String, String> fields = const {},
    List<({String filename, String mime, Uint8List bytes})> attachments =
        const [],
  }) =>
      _inner.postStream(path: _p(path), fields: fields, attachments: attachments);

  @override
  Stream<SseEvent> getStream({required String path}) =>
      _inner.getStream(path: _p(path));

  /// The inner client belongs to the hub's base service and outlives this
  /// wrapper, so closing here must not propagate.
  @override
  void close() {}

  @override
  Future<bool> get isConfigured => _inner.isConfigured;

  @override
  Future<void> setServerUrl(String serverUrl) => _inner.setServerUrl(serverUrl);

  @override
  Future<void> setToken(String token) => _inner.setToken(token);

  @override
  Future<void> setUsername(String username) => _inner.setUsername(username);

  @override
  Future<void> clearCredentials() => _inner.clearCredentials();

  @override
  Future<void> init() => _inner.init();

  @override
  bool get isNative => _inner.isNative;

  @override
  Future<String?> get serverUrl => _inner.serverUrl;

  @override
  Future<String?> get token => _inner.token;
}
