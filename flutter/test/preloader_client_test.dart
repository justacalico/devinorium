import 'dart:async';
import 'dart:typed_data';

import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/api/preloader_client.dart';
import 'package:devinorium_frontend/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeClient implements BaseApiClient {
  final _calls = <String>[];
  final _getCompleters = <Completer<Map<String, dynamic>>>[];
  final _getListCompleters = <Completer<List<Map<String, dynamic>>>>[];

  List<String> get calls => _calls;

  void resolveGet(int index, Map<String, dynamic> value) {
    _getCompleters[index].complete(value);
  }

  void resolveGetList(int index, List<Map<String, dynamic>> value) {
    _getListCompleters[index].complete(value);
  }

  @override
  Future<Map<String, dynamic>> get(String path) {
    _calls.add('GET $path');
    final c = Completer<Map<String, dynamic>>();
    _getCompleters.add(c);
    return c.future;
  }

  @override
  Future<List<Map<String, dynamic>>> getList(String path) {
    _calls.add('GETLIST $path');
    final c = Completer<List<Map<String, dynamic>>>();
    _getListCompleters.add(c);
    return c.future;
  }

  @override
  Future<Map<String, dynamic>> post(String path, [Object? body]) {
    _calls.add('POST $path');
    return Future.value({});
  }

  @override
  Future<Map<String, dynamic>> put(String path, [Object? body]) {
    _calls.add('PUT $path');
    return Future.value({});
  }

  @override
  Future<Map<String, dynamic>> patch(String path, [Object? body]) {
    _calls.add('PATCH $path');
    return Future.value({});
  }

  @override
  Future<Map<String, dynamic>> delete(String path) {
    _calls.add('DELETE $path');
    return Future.value({});
  }

  @override
  Future<Map<String, dynamic>> deleteWithBody(String path, Object body) {
    _calls.add('DELETE $path');
    return Future.value({});
  }

  @override
  Future<Map<String, dynamic>> uploadMultipart(
    String path,
    Map<String, String> fields,
    List<({String filename, String mime, Uint8List bytes})> files,
  ) {
    _calls.add('UPLOAD $path');
    return Future.value({});
  }

  @override
  Stream<SseEvent> getStream({required String path}) => const Stream.empty();

  @override
  Stream<SseEvent> sendStream({
    required String path,
    required String prompt,
    String? mode,
    String? clientMessageId,
    List<({String filename, String mime, Uint8List bytes})> attachments =
        const [],
    List<PathRef> contextPaths = const [],
  }) => const Stream.empty();

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
}

void main() {
  group('PreloaderClient', () {
    test('caches getList and reuses the value', () async {
      final inner = _FakeClient();
      final client = PreloaderClient(inner);

      final f1 = client.getList('/api/projects');
      final f2 = client.getList('/api/projects');
      inner.resolveGetList(0, [
        {'id': '1'},
      ]);

      expect(await f1, [
        {'id': '1'},
      ]);
      expect(await f2, [
        {'id': '1'},
      ]);
      expect(inner.calls, ['GETLIST /api/projects']);
    });

    test('coalesces in-flight get requests but does not cache them', () async {
      final inner = _FakeClient();
      final client = PreloaderClient(inner);

      final f1 = client.get('/api/threads/a');
      final f2 = client.get('/api/threads/a');
      inner.resolveGet(0, {'id': 'a'});

      expect(await f1, {'id': 'a'});
      expect(await f2, {'id': 'a'});

      // A later call must hit the network again because GET detail pages
      // are too volatile to cache.
      final f3 = client.get('/api/threads/a');
      inner.resolveGet(1, {'id': 'a'});
      await f3;
      expect(inner.calls, ['GET /api/threads/a', 'GET /api/threads/a']);
    });

    test('invalidates getList cache on write operations', () async {
      final inner = _FakeClient();
      final client = PreloaderClient(inner);

      final f1 = client.getList('/api/projects');
      inner.resolveGetList(0, [
        {'id': '1'},
      ]);
      await f1;

      await client.post('/api/projects', {'name': 'p'});

      final f2 = client.getList('/api/projects');
      inner.resolveGetList(1, [
        {'id': '2'},
      ]);
      await f2;

      expect(inner.calls, [
        'GETLIST /api/projects',
        'POST /api/projects',
        'GETLIST /api/projects',
      ]);
    });

    test('clearCredentials clears the cache', () async {
      final inner = _FakeClient();
      final client = PreloaderClient(inner);

      final f1 = client.getList('/api/projects');
      inner.resolveGetList(0, [
        {'id': '1'},
      ]);
      await f1;

      await client.clearCredentials();
      final f2 = client.getList('/api/projects');
      inner.resolveGetList(1, [
        {'id': '1'},
      ]);
      await f2;

      expect(inner.calls, ['GETLIST /api/projects', 'GETLIST /api/projects']);
    });
  });
}
