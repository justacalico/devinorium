import 'dart:convert';
import 'dart:typed_data';

import 'package:devinorium_frontend/api/api_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';

http.Response _json(int status, Object body) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );

String? _readBody(http.BaseRequest req) {
  if (req is http.Request) return req.body;
  return null;
}

void main() {
  group('ApiClient GET/POST/PATCH/DELETE', () {
    test('get returns parsed JSON object', () async {
      final mock = MockClient((req) async => _json(200, {'id': 1, 'username': 'owner'}));
      final client = ApiClient.withClient(mock);
      final res = await client.get('/api/auth/me');
      expect(res, {'id': 1, 'username': 'owner'});
    });

    test('post sends JSON body and returns response', () async {
      final mock = MockClient((req) async {
        expect(req.method, 'POST');
        expect(req.headers['content-type'], 'application/json; charset=utf-8');
        final body = jsonDecode(_readBody(req)!);
        expect(body['username'], 'owner');
        return _json(200, {'ok': true});
      });
      final client = ApiClient.withClient(mock);
      final res = await client.post('/api/auth/login', {'username': 'owner', 'password': 'pw'});
      expect(res, {'ok': true});
    });

    test('patch sends JSON body', () async {
      final mock = MockClient((req) async {
        expect(req.method, 'PATCH');
        final body = jsonDecode(_readBody(req)!);
        expect(body['title'], 'new');
        return _json(200, {});
      });
      final client = ApiClient.withClient(mock);
      await client.patch('/api/threads/1', {'title': 'new'});
    });

    test('deleteWithBody sends JSON body for 204', () async {
      final mock = MockClient((req) async {
        expect(req.method, 'DELETE');
        final body = jsonDecode(_readBody(req)!);
        expect(body['worktree_path'], '/tmp/wt');
        return http.Response('', 204);
      });
      final client = ApiClient.withClient(mock);
      final res = await client.deleteWithBody('/api/projects/1/git/worktrees', {
        'worktree_path': '/tmp/wt',
      });
      expect(res, isEmpty);
    });

    test('delete returns empty object for 204', () async {
      final mock = MockClient((req) async {
        expect(req.method, 'DELETE');
        return http.Response('', 204);
      });
      final client = ApiClient.withClient(mock);
      final res = await client.delete('/api/threads/1');
      expect(res, isEmpty);
    });

    test('throws ApiException with backend error message', () async {
      final mock = MockClient((req) async => _json(400, {'error': 'bad request'}));
      final client = ApiClient.withClient(mock);
      expect(
        () => client.get('/api/threads'),
        throwsA(isA<ApiException>().having((e) => e.message, 'message', 'bad request').having(
          (e) => e.statusCode,
          'statusCode',
          400,
        )),
      );
    });

    test('throws ApiException with plain text when error has no json', () async {
      final mock = MockClient((req) async => http.Response('something broke', 500));
      final client = ApiClient.withClient(mock);
      expect(
        () => client.get('/api/threads'),
        throwsA(isA<ApiException>().having((e) => e.message, 'message', 'something broke')),
      );
    });

    test('throws ApiException with status code when body is empty', () async {
      final mock = MockClient((req) async => http.Response('', 502));
      final client = ApiClient.withClient(mock);
      expect(
        () => client.get('/api/threads'),
        throwsA(isA<ApiException>().having((e) => e.message, 'message', 'HTTP 502')),
      );
    });

    test('throws for unexpected response shape', () async {
      final mock = MockClient((req) async => _json(200, 'plain string'));
      final client = ApiClient.withClient(mock);
      expect(() => client.get('/api/threads'), throwsA(isA<ApiException>()));
    });

    test('wraps bare list as _list', () async {
      final mock = MockClient((req) async => _json(200, [1, 2]));
      final client = ApiClient.withClient(mock);
      final res = await client.get('/api/threads');
      expect(res['_list'], [1, 2]);
    });
  });

  group('ApiClient getList', () {
    test('returns list of objects', () async {
      final mock = MockClient((req) async {
        expect(req.method, 'GET');
        return _json(200, [
          {'id': 'a'},
          {'id': 'b'},
        ]);
      });
      final client = ApiClient.withClient(mock);
      final res = await client.getList('/api/threads');
      expect(res, hasLength(2));
      expect(res.first['id'], 'a');
    });

    test('throws ApiException on error status', () async {
      final mock = MockClient((req) async => _json(401, {'error': 'unauthorized'}));
      final client = ApiClient.withClient(mock);
      expect(
        () => client.getList('/api/threads'),
        throwsA(isA<ApiException>().having((e) => e.message, 'message', 'unauthorized')),
      );
    });

    test('throws when response is not a list', () async {
      final mock = MockClient((req) async => _json(200, {'ok': true}));
      final client = ApiClient.withClient(mock);
      expect(
        () => client.getList('/api/threads'),
        throwsA(isA<ApiException>().having((e) => e.message, 'message', 'expected a list')),
      );
    });
  });

  group('ApiClient uploadMultipart', () {
    test('uploads files and returns parsed response', () async {
      final mock = MockClient((req) async {
        expect(req.method, 'POST');
        expect(req.headers['Accept'], 'application/json');
        return _json(200, {'ok': true});
      });
      final client = ApiClient.withClient(mock);
      final files = <({String filename, String mime, Uint8List bytes})>[
        (filename: 'a.txt', mime: 'text/plain', bytes: Uint8List.fromList([1, 2, 3])),
      ];
      final res = await client.uploadMultipart('/api/files', {'path': '/'}, files);
      expect(res, {'ok': true});
    });

    test('throws on error', () async {
      final mock = MockClient((req) async => _json(400, {'error': 'bad file'}));
      final client = ApiClient.withClient(mock);
      final files = <({String filename, String mime, Uint8List bytes})>[];
      expect(
        () => client.uploadMultipart('/api/files', {}, files),
        throwsA(isA<ApiException>().having((e) => e.message, 'message', 'bad file')),
      );
    });
  });

  group('SseEvent', () {
    test('holds event and data', () {
      final ev = SseEvent('chunk', 'hello');
      expect(ev.event, 'chunk');
      expect(ev.data, 'hello');
    });
  });
}
