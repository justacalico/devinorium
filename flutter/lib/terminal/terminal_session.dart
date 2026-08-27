import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:xterm/xterm.dart';

import '../api/api_service.dart';
import 'local_pty_stub.dart'
    if (dart.library.io) 'local_pty_io.dart';
import 'web_socket_factory.dart';

enum TerminalStatus {
  idle,
  connecting,
  connected,
  disconnected,
  exited,
}

/// Controller for one terminal (local PTY or remote backend session).
class TerminalSession extends ChangeNotifier {
  TerminalSession({required this.id, required this.isLocal})
      : terminal = Terminal(maxLines: 10000) {
    _attach();
  }

  final String id;
  final bool isLocal;
  final Terminal terminal;

  TerminalStatus _status = TerminalStatus.idle;
  TerminalStatus get status => _status;

  final _completed = Completer<void>();
  Future<void> get completed => _completed.future;

  void _setStatus(TerminalStatus value) {
    if (_status == value) return;
    _status = value;
    notifyListeners();
  }

  void _attach() {}

  void _complete() {
    if (!_completed.isCompleted) _completed.complete();
  }

  @override
  void dispose() {
    terminal.onOutput = null;
    terminal.onResize = null;
    _complete();
    super.dispose();
  }
}

class LocalTerminalSession extends TerminalSession {
  LocalTerminalSession({required super.id}) : super(isLocal: true) {
    _setStatus(TerminalStatus.connected);
    _backend.start();
  }

  late final _backend = LocalPtyBackend(terminal);

  @override
  void _attach() {
    terminal.onOutput = _onOutput;
    terminal.onResize = _onResize;
  }

  void _onOutput(String data) => _backend.write(data);

  void _onResize(int w, int h, int pw, int ph) => _backend.resize(w, h);

  @override
  void dispose() {
    _backend.dispose();
    super.dispose();
  }
}

class RemoteTerminalSession extends TerminalSession {
  RemoteTerminalSession({
    required super.id,
    required this.uri,
    this.token,
    this.reconnect = true,
    WebSocketChannel Function(Uri, {String? token})? connector,
  })  : _connector = connector ?? connectTerminalWebSocket,
        super(isLocal: false) {
    _connect();
  }

  final Uri uri;
  final String? token;
  final bool reconnect;

  final WebSocketChannel Function(Uri, {String? token}) _connector;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  int _reconnectAttempts = 0;
  static const _maxReconnectAttempts = 5;

  @override
  void _attach() {
    terminal.onOutput = _onOutput;
    terminal.onResize = _onResize;
  }

  void _connect() {
    _setStatus(TerminalStatus.connecting);
    try {
      _channel = _connector(uri, token: token);
      _sub = _channel!.stream.listen(
        _onMessage,
        onError: _onError,
        onDone: _onDone,
      );
      _setStatus(TerminalStatus.connected);
      _reconnectAttempts = 0;
      _sendResize(terminal.viewWidth, terminal.viewHeight);
    } catch (e) {
      terminal.write('[connection error: $e]\r\n');
      _onError(e);
    }
  }

  void _onMessage(dynamic message) {
    if (message is List<int>) {
      final text = utf8.decode(message, allowMalformed: true);
      terminal.write(text);
    } else if (message is String) {
      try {
        final data = jsonDecode(message) as Map<String, dynamic>;
        if (data['type'] == 'exited') {
          final code = data['code'];
          terminal.write('\r\n[session exited with code $code]\r\n');
          _setStatus(TerminalStatus.exited);
          _complete();
        }
      } catch (_) {
        // Ignore malformed text messages.
      }
    }
  }

  void _onError(Object error) {
    _setStatus(TerminalStatus.disconnected);
    _sub?.cancel();
    _channel = null;
    if (!reconnect || _reconnectAttempts >= _maxReconnectAttempts) {
      _setStatus(TerminalStatus.exited);
      _complete();
      return;
    }
    _reconnectAttempts++;
    final delay = Duration(
      milliseconds: 500 * (pow(2, _reconnectAttempts - 1).toInt()),
    );
    Future.delayed(delay, _connect);
  }

  void _onDone() {
    if (_status == TerminalStatus.exited) return;
    _onError('WebSocket closed');
  }

  void _onOutput(String data) {
    _send(jsonEncode({'type': 'input', 'data': data}));
  }

  void _onResize(int w, int h, int pw, int ph) => _sendResize(w, h);

  void _sendResize(int cols, int rows) {
    _send(jsonEncode({'type': 'resize', 'cols': cols, 'rows': rows}));
  }

  void _send(String data) {
    if (_channel != null && _status == TerminalStatus.connected) {
      _channel!.sink.add(data);
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _channel?.sink.close();
    super.dispose();
  }
}

/// Factory signature for creating a [TerminalSession] for a thread.
///
/// This is the default factory used by [ThreadTerminalPanel] so tests can
/// inject a fake session without starting a real PTY or WebSocket.
///
/// Non-test callers should pass [createTerminalSession] and let it handle the
/// actual local/remote backend.
typedef TerminalSessionFactory = Future<TerminalSession> Function({
  required ApiService api,
  required String threadId,
  required bool local,
});

/// Create a local or remote terminal session for [threadId].
Future<TerminalSession> createTerminalSession({
  required ApiService api,
  required String threadId,
  required bool local,
}) async {
  if (local) {
    return LocalTerminalSession(id: 'local-${DateTime.now().millisecondsSinceEpoch}');
  }
  final sessionId = await api.createTerminalSession(threadId);
  final uri = await api.terminalWebSocketUri(sessionId);
  final token = await api.terminalToken;
  return RemoteTerminalSession(id: sessionId, uri: uri, token: token);
}
