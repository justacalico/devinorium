import 'dart:convert';

import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/api/native_api_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_test/flutter_test.dart';

http.Response _json(int status, Object body) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('NativeApiClient', () {
    test('isConfigured is false when empty', () async {
      final client = NativeApiClient();
      expect(await client.isConfigured, false);
    });

    test('setServerUrl and setToken make it configured', () async {
      final client = NativeApiClient();
      await client.setServerUrl('http://localhost:7878');
      await client.setToken('abc123');
      expect(await client.isConfigured, true);
    });

    test('sends origin header for server url', () async {
      String? capturedOrigin;
      final mock = MockClient((req) async {
        capturedOrigin = req.headers['origin'];
        return _json(200, {'ok': true});
      });
      final client = NativeApiClient(client: mock);
      await client.setServerUrl('http://server.example:7878/');
      await client.post('/api/auth/login', {'username': 'a', 'password': 'b'});
      expect(capturedOrigin, 'http://server.example:7878');
    });

    test('sends bearer token header', () async {
      String? capturedAuth;
      final mock = MockClient((req) async {
        capturedAuth = req.headers['authorization'];
        return _json(200, {'ok': true});
      });
      final client = NativeApiClient(client: mock);
      await client.setServerUrl('http://localhost:7878');
      await client.setToken('mytoken');
      await client.post('/api/auth/logout');
      expect(capturedAuth, 'Bearer mytoken');
    });

    test('uses absolute server url', () async {
      String? capturedPath;
      final mock = MockClient((req) async {
        capturedPath = req.url.toString();
        return _json(200, {'ok': true});
      });
      final client = NativeApiClient(client: mock);
      await client.setServerUrl('http://server.example:7878/');
      await client.setToken('t');
      await client.get('/api/auth/me');
      expect(capturedPath, 'http://server.example:7878/api/auth/me');
    });

    test('parses backend error', () async {
      final mock = MockClient((_) async => _json(403, {'error': 'nope'}));
      final client = NativeApiClient(client: mock);
      await client.setServerUrl('http://localhost:7878');
      await client.setToken('t');
      expect(
        client.get('/api/auth/me'),
        throwsA(
          isA<ApiException>().having((e) => e.message, 'message', 'nope'),
        ),
      );
    });

    test('keeps short plain-text error bodies', () async {
      final mock = MockClient((_) async => http.Response('something broke', 500));
      final client = NativeApiClient(client: mock);
      await client.setServerUrl('http://localhost:7878');
      expect(
        client.get('/api/auth/me'),
        throwsA(
          isA<ApiException>().having((e) => e.message, 'message', 'something broke'),
        ),
      );
    });

    test('falls back to status for html error pages', () async {
      final mock = MockClient(
        (_) async => http.Response('<html><body>Bad Gateway</body></html>', 502),
      );
      final client = NativeApiClient(client: mock);
      await client.setServerUrl('http://localhost:7878');
      expect(
        client.get('/api/auth/me'),
        throwsA(
          isA<ApiException>().having((e) => e.message, 'message', 'HTTP 502'),
        ),
      );
    });

    test('truncates very long error bodies', () async {
      final mock = MockClient((_) async => http.Response('x' * 500, 500));
      final client = NativeApiClient(client: mock);
      await client.setServerUrl('http://localhost:7878');
      expect(
        client.get('/api/auth/me'),
        throwsA(
          isA<ApiException>().having((e) => e.message, 'message', '${'x' * 300}…'),
        ),
      );
    });

    test('sanitizes error body on list endpoints', () async {
      final mock = MockClient((_) async => http.Response('<h1>oops</h1>', 503));
      final client = NativeApiClient(client: mock);
      await client.setServerUrl('http://localhost:7878');
      expect(
        client.getList('/api/threads'),
        throwsA(
          isA<ApiException>().having((e) => e.message, 'message', 'HTTP 503'),
        ),
      );
    });

    test('preserves structured data on json errors', () async {
      final mock = MockClient(
        (_) async => _json(400, {'error': 'bad request', 'code': 'E_BAD'}),
      );
      final client = NativeApiClient(client: mock);
      await client.setServerUrl('http://localhost:7878');
      expect(
        client.get('/api/auth/me'),
        throwsA(
          isA<ApiException>()
              .having((e) => e.message, 'message', 'bad request')
              .having((e) => e.data?['code'], 'data.code', 'E_BAD'),
        ),
      );
    });
  });
}
