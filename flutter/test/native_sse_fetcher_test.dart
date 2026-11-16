import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:devinorium_frontend/api/native_api_client.dart';
import 'package:devinorium_frontend/api/native_sse_fetcher.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('NativeApiClient SSE', () {
    late HttpServer server;
    late String baseUrl;
    String? lastSendBody;
    var requests = 0;
    late Completer<void> requestSeen;

    setUp(() async {
      SharedPreferences.setMockInitialValues({
        'devinorium_server_url': '',
        'devinorium_token': '',
      });
      lastSendBody = null;
      requests = 0;
      requestSeen = Completer<void>();

      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      baseUrl = 'http://localhost:${server.port}';

      server.listen((request) async {
        requests += 1;
        if (!requestSeen.isCompleted) requestSeen.complete();
        final body = await utf8.decoder.bind(request).join();

        if (request.uri.path == '/api/threads/t/send/stream') {
          lastSendBody = body;
          final response = request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.parse('text/event-stream')
            ..headers.set('cache-control', 'no-cache');

          // Emit a few events then keep the connection open, so the client can
          // cancel before the response ends.
          for (var i = 0; i < 3; i++) {
            response.write('event: token\ndata: ${jsonEncode({'chunk': i})}\n\n');
            await response.flush();
            await Future.delayed(const Duration(milliseconds: 50));
          }

          // Hold the connection open so cancellation actually cancels.
          await Future.delayed(const Duration(seconds: 30));
          try {
            await response.close();
          } catch (_) {}
        } else {
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({'ok': true}))
            ..close();
        }
      });
    });

    tearDown(() async {
      await server.close();
    });

    test('cancelling a send stream does not break the shared client', () async {
      final client = NativeApiClient();
      await client.setServerUrl(baseUrl);
      await client.setToken('test');

      final stream = client.sendStream(
        path: '/api/threads/t/send/stream',
        prompt: 'hello',
      );

      final sub = stream.listen(null);
      // Give the stream time to connect and start receiving.
      await Future.delayed(const Duration(milliseconds: 200));
      await sub.cancel();

      // This request uses the same shared client that the UI uses after a
      // stream is cancelled; it must not throw "Client is already closed".
      final resp = await client.get('/other');
      expect(resp, {'ok': true});
    });

    test('an unlistened stream fires no request', () async {
      final stream = nativeSseStream(
        clientFactory: http.Client.new,
        baseUrl: baseUrl,
        token: 'test',
        path: '/other',
        method: 'GET',
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(requests, 0);

      final sub = stream.listen(null);
      await requestSeen.future.timeout(const Duration(seconds: 5));
      await sub.cancel();
      expect(requests, 1);
    });

    test('an unconfigured stream errors without creating a client', () async {
      var created = 0;
      final stream = nativeSseStream(
        clientFactory: () {
          created += 1;
          return http.Client();
        },
        baseUrl: '',
        token: 'test',
        path: '/other',
        method: 'GET',
      );
      await expectLater(stream.first, throwsA(anything));
      expect(created, 0);
    });

    test('sendStream forwards context paths as a multipart field', () async {
      final client = NativeApiClient();
      await client.setServerUrl(baseUrl);
      await client.setToken('test');

      final stream = client.sendStream(
        path: '/api/threads/t/send/stream',
        prompt: 'hello',
        contextPaths: [
          (path: 'src/main.dart', isDir: false),
          (path: 'docs', isDir: true),
        ],
      );

      final sub = stream.listen(null);
      await Future.delayed(const Duration(milliseconds: 200));
      await sub.cancel();

      final body = lastSendBody;
      expect(body, isNotNull);
      expect(body, contains('name="context_paths"'));
      expect(
        body,
        contains(
          jsonEncode([
            {'path': 'src/main.dart', 'is_dir': false},
            {'path': 'docs', 'is_dir': true},
          ]),
        ),
      );
    });
  });
}
