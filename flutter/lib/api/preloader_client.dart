import 'dart:async';
import 'dart:typed_data';

import '../l10n/global_l10n.dart';
import '../models/models.dart';
import '../utils/preloader.dart';
import 'api_client.dart';

/// Caches safe GET list responses and coalesces in-flight detail GETs so the
/// app does not pay the 100ms+ network round trip more than necessary.
///
/// Mutating requests clear the list cache so the UI does not show stale data.
class PreloaderClient implements BaseApiClient {
  PreloaderClient(
    this._inner, {
    Preloader? preloader,
    Duration? inFlightCeiling,
  }) : _preloader = preloader ?? Preloader(),
       _inFlightCeiling = inFlightCeiling ?? _defaultInFlightCeiling;

  final BaseApiClient _inner;
  final Preloader _preloader;
  final Duration _inFlightCeiling;

  /// The wrapped client, exposed so callers can inspect the platform client.
  BaseApiClient get inner => _inner;

  @override
  void close() => _inner.close();

  static const _listTtl = Duration(seconds: 2);

  /// Upper bound for a request tracked by the preloader. A half-dead socket
  /// can hold an HTTP request open far past the point where the UI gave up;
  /// without a ceiling the zombie in-flight entry would keep coalescing
  /// retries onto itself and the panel behind it could never recover.
  static const _defaultInFlightCeiling = Duration(seconds: 30);

  @override
  Future<Map<String, dynamic>> get(String path) => _preloader.load(
    'GET:$path',
    () => _inner.get(path).timeout(_inFlightCeiling, onTimeout: _timedOut),
    ttl: Duration.zero,
  );

  @override
  Future<List<Map<String, dynamic>>> getList(String path) => _preloader.load(
    'GETLIST:$path',
    () => _inner.getList(path).timeout(_inFlightCeiling, onTimeout: _timedOut),
    ttl: _listTtl,
  );

  static Never _timedOut() => throw ApiException(appL10n.requestTimedOut, 0);

  @override
  Stream<SseEvent> getStream({required String path}) =>
      _inner.getStream(path: path);

  @override
  Future<bool> get isConfigured => _inner.isConfigured;

  @override
  Future<void> setServerUrl(String serverUrl) => _inner.setServerUrl(serverUrl);

  @override
  Future<void> setToken(String token) => _inner.setToken(token);

  @override
  Future<void> setUsername(String username) => _inner.setUsername(username);

  @override
  Future<void> clearCredentials() {
    _preloader.clear();
    return _inner.clearCredentials();
  }

  @override
  Future<void> init() => _inner.init();

  @override
  bool get isNative => _inner.isNative;

  @override
  Future<String?> get serverUrl => _inner.serverUrl;

  @override
  Future<String?> get token => _inner.token;

  @override
  String get pathPrefix => _inner.pathPrefix;

  @override
  Future<Map<String, dynamic>> post(String path, [Object? body]) =>
      _mutate(() => _inner.post(path, body));

  @override
  Future<Map<String, dynamic>> put(String path, [Object? body]) =>
      _mutate(() => _inner.put(path, body));

  @override
  Future<Map<String, dynamic>> patch(String path, [Object? body]) =>
      _mutate(() => _inner.patch(path, body));

  @override
  Future<Map<String, dynamic>> delete(String path) =>
      _mutate(() => _inner.delete(path));

  @override
  Future<Map<String, dynamic>> deleteWithBody(String path, Object body) =>
      _mutate(() => _inner.deleteWithBody(path, body));

  @override
  Future<Map<String, dynamic>> uploadMultipart(
    String path,
    Map<String, String> fields,
    List<({String filename, String mime, Uint8List bytes})> files,
  ) => _mutate(() => _inner.uploadMultipart(path, fields, files));

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
  }) => _inner.sendStream(
    path: path,
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
  }) => _inner.postStream(path: path, fields: fields, attachments: attachments);

  Future<T> _mutate<T>(Future<T> Function() action) async {
    final result = await action();
    _preloader.invalidate('GETLIST:');
    return result;
  }
}
