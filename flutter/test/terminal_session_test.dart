import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/api/api_service.dart';
import 'package:devinorium_frontend/terminal/terminal_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class _FakeWebSocketSink extends DelegatingStreamSink<dynamic>
    implements WebSocketSink {
  _FakeWebSocketSink(super.sink);

  @override
  Future close([int? closeCode, String? closeReason]) => super.close();
}

class _FakeWebSocketChannel extends StreamChannelMixin<dynamic>
    implements WebSocketChannel {
  _FakeWebSocketChannel() {
    _ready.complete();
  }

  final _controller = StreamChannelController<dynamic>(
    sync: true,
    allowForeignErrors: false,
  );
  final _ready = Completer<void>();

  @override
  String? get protocol => null;

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  Future<void> get ready => _ready.future;

  @override
  Stream<dynamic> get stream => _controller.foreign.stream;

  @override
  late final WebSocketSink sink = _FakeWebSocketSink(_controller.foreign.sink);

  /// The remote side: writing here goes to [stream], reading here sees [sink].
  StreamSink<dynamic> get remoteSink => _controller.local.sink;
  Stream<dynamic> get remoteStream => _controller.local.stream;
}

class _FakeBaseClient extends BaseApiClient {
  String? _serverUrl;
  String? _token;

  @override
  Future<bool> get isConfigured => Future.value(true);

  @override
  Future<Map<String, dynamic>> get(String path) => throw UnimplementedError();

  @override
  Future<List<Map<String, dynamic>>> getList(String path) =>
      throw UnimplementedError();

  @override
  Stream<SseEvent> getStream({required String path}) =>
      throw UnimplementedError();

  @override
  Future<Map<String, dynamic>> post(String path, [Object? body]) async =>
      {'id': 'sess-42'};

  @override
  Future<Map<String, dynamic>> put(String path, [Object? body]) =>
      throw UnimplementedError();

  @override
  Future<Map<String, dynamic>> patch(String path, [Object? body]) =>
      throw UnimplementedError();

  @override
  Future<Map<String, dynamic>> delete(String path) =>
      throw UnimplementedError();

  @override
  Future<Map<String, dynamic>> deleteWithBody(String path, Object body) =>
      throw UnimplementedError();

  @override
  Future<Map<String, dynamic>> uploadMultipart(
    String path,
    Map<String, String> fields,
    List<({String filename, String mime, Uint8List bytes})> files,
  ) =>
      throw UnimplementedError();

  @override
  Stream<SseEvent> sendStream({
    required String path,
    required String prompt,
    String? mode,
    List<({String filename, String mime, Uint8List bytes})>? attachments,
  }) =>
      throw UnimplementedError();

  @override
  Future<void> setServerUrl(String serverUrl) async => _serverUrl = serverUrl;

  @override
  Future<void> setToken(String token) async => _token = token;

  @override
  Future<void> setUsername(String username) => Future.value();

  @override
  Future<void> clearCredentials() => Future.value();

  @override
  Future<void> init() => Future.value();

  @override
  bool get isNative => true;

  @override
  Future<String?> get serverUrl => Future.value(_serverUrl);

  @override
  Future<String?> get token => Future.value(_token);
}

class _FailingConnector {
  var calls = 0;

  WebSocketChannel call(Uri uri, {String? token}) {
    calls++;
    throw Exception('connection refused');
  }
}

WebSocketChannel Function(Uri, {String? token}) _returnFake(
        _FakeWebSocketChannel fake) =>
    (Uri uri, {String? token}) => fake;

void main() {
  group('RemoteTerminalSession', () {
    test('decodes binary output and writes to terminal', () {
      final fake = _FakeWebSocketChannel();
      final session = RemoteTerminalSession(
        id: 'r1',
        uri: Uri.parse('ws://localhost/ws'),
        connector: _returnFake(fake),
      );
      addTearDown(session.dispose);

      final payload = utf8.encode('hello world');
      fake.remoteSink.add(payload);

      expect(session.terminal.buffer.getText(), contains('hello world'));
    });

    test('sends JSON resize and input frames', () {
      final fake = _FakeWebSocketChannel();
      final outgoing = <dynamic>[];
      fake.remoteStream.listen(outgoing.add);

      final session = RemoteTerminalSession(
        id: 'r2',
        uri: Uri.parse('ws://localhost/ws'),
        connector: _returnFake(fake),
      );
      addTearDown(session.dispose);

      session.terminal.onOutput!('ls -la');

      expect(outgoing.length, greaterThanOrEqualTo(2));
      expect(
        jsonDecode(outgoing[0] as String),
        {'type': 'resize', 'cols': 80, 'rows': 24},
      );
      expect(
        jsonDecode(outgoing[1] as String),
        {'type': 'input', 'data': 'ls -la'},
      );
    });

    testWidgets('reconnects on failure and eventually exits', (tester) async {
      final connector = _FailingConnector();
      final session = RemoteTerminalSession(
        id: 'r3',
        uri: Uri.parse('ws://localhost/ws'),
        reconnect: true,
        connector: connector.call,
      );
      addTearDown(session.dispose);

      // Allow all reconnect delays to fire (500 + 1000 + 2000 + 4000 + 8000 ms).
      await tester.pump(const Duration(seconds: 20));

      expect(connector.calls, greaterThanOrEqualTo(3));
      expect(session.status, TerminalStatus.exited);
    });

    test('exited message completes the session', () {
      final fake = _FakeWebSocketChannel();
      final session = RemoteTerminalSession(
        id: 'r4',
        uri: Uri.parse('ws://localhost/ws'),
        connector: _returnFake(fake),
      );
      addTearDown(session.dispose);

      fake.remoteSink.add(jsonEncode({'type': 'exited', 'code': 0}));

      expect(session.completed, completes);
    });
  });

  group('ApiService terminal helpers', () {
    test('creates remote session and builds WebSocket uri', () async {
      final client = _FakeBaseClient();
      await client.setServerUrl('http://localhost:3000');
      final api = ApiService(client: client);

      final id = await api.createTerminalSession('thread-1');
      expect(id, 'sess-42');

      final uri = await api.terminalWebSocketUri('sess-42');
      expect(uri.scheme, 'ws');
      expect(uri.host, 'localhost');
      expect(uri.port, 3000);
      expect(uri.path, '/api/terminal/sessions/sess-42/ws');

      expect(await api.terminalToken, isNull);
    });

    test('exposes bearer token for native clients', () async {
      final client = _FakeBaseClient();
      await client.setServerUrl('http://localhost:3000');
      await client.setToken('abc-123');
      final api = ApiService(client: client);

      expect(await api.terminalToken, 'abc-123');
    });
  });
}
