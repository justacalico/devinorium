import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show ScrollController;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:xterm/xterm.dart';

import '../api/api_service.dart';
import '../l10n/global_l10n.dart';
import 'local_pty_stub.dart' if (dart.library.io) 'local_pty_io.dart';
import 'web_socket_factory.dart';

enum TerminalStatus { idle, connecting, connected, disconnected, exited }

/// Controller for one terminal (local PTY or remote backend session).
class TerminalSession extends ChangeNotifier {
  TerminalSession({required this.id, required this.isLocal})
    : terminal = Terminal(maxLines: 10000) {
    _attach();
  }

  final String id;
  final bool isLocal;
  final Terminal terminal;

  /// Shared with [TerminalViewWidget] so view state (selection, scroll
  /// position) survives the panel being hidden or remounted in another view.
  final controller = TerminalController();
  final scrollController = ScrollController();

  TerminalStatus _status = TerminalStatus.idle;
  TerminalStatus get status => _status;

  /// Whether the terminal buffer contains no visible content.
  bool get isBlank {
    final lines = terminal.buffer.lines;
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].getText().trim().isNotEmpty) {
        return false;
      }
    }
    return true;
  }

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
    controller.dispose();
    scrollController.dispose();
    _complete();
    super.dispose();
  }
}

class LocalTerminalSession extends TerminalSession {
  LocalTerminalSession({required super.id, this.workingDir})
    : super(isLocal: true) {
    _setStatus(TerminalStatus.connected);
    _backend.start(workingDirectory: workingDir);
  }

  /// Directory the local shell starts in — the thread's working directory
  /// when it resolves on this device.
  final String? workingDir;

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
  }) : _connector = connector ?? connectTerminalWebSocket,
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
  bool _disposed = false;
  static const _maxReconnectAttempts = 5;

  // Reset only after the socket survives this window; resetting on every
  // short-lived connect would let a flapping link retry forever.
  static const _stableWindow = Duration(seconds: 10);
  Timer? _stabilityTimer;

  // Keystrokes typed while the socket reconnects, flushed on reconnect.
  final _inputBuffer = StringBuffer();
  static const _inputBufferLimit = 4096;

  // Binary frames arrive independently but UTF-8 sequences can span them;
  // the sink buffers partial code units between frames. Recreated on every
  // connect since a new socket carries no pending bytes.
  ByteConversionSink? _utf8Sink;

  @override
  void _attach() {
    terminal.onOutput = _onOutput;
    terminal.onResize = _onResize;
  }

  void _connect() {
    _setStatus(TerminalStatus.connecting);
    _utf8Sink = utf8.decoder.startChunkedConversion(
      _TerminalTextSink(terminal.write),
    );
    try {
      _channel = _connector(uri, token: token);
      _sub = _channel!.stream.listen(
        _onMessage,
        onError: _onError,
        onDone: _onDone,
      );
      _setStatus(TerminalStatus.connected);
      _stabilityTimer?.cancel();
      _stabilityTimer = Timer(_stableWindow, () {
        if (_status == TerminalStatus.connected) _reconnectAttempts = 0;
      });
      _sendResize(terminal.viewWidth, terminal.viewHeight);
      _flushInputBuffer();
    } catch (e) {
      terminal.write('${appL10n.terminalConnectionError('$e')}\r\n');
      _onError(e);
    }
  }

  void _onMessage(dynamic message) {
    if (_disposed) return;
    if (message is List<int>) {
      _utf8Sink?.add(message);
    } else if (message is String) {
      try {
        final data = jsonDecode(message) as Map<String, dynamic>;
        if (data['type'] == 'exited') {
          final code = data['code'];
          terminal.write('\r\n${appL10n.terminalSessionExited('$code')}\r\n');
          _stabilityTimer?.cancel();
          _setStatus(TerminalStatus.exited);
          _complete();
        }
      } catch (_) {
        // Ignore malformed text messages.
      }
    }
  }

  void _onError(Object error) {
    if (_disposed) return;
    _setStatus(TerminalStatus.disconnected);
    _sub?.cancel();
    _channel = null;
    _utf8Sink?.close();
    _utf8Sink = null;
    if (!reconnect || _reconnectAttempts >= _maxReconnectAttempts) {
      _stabilityTimer?.cancel();
      _inputBuffer.clear();
      _setStatus(TerminalStatus.exited);
      _complete();
      return;
    }
    _reconnectAttempts++;
    final delay = Duration(
      milliseconds: 500 * (pow(2, _reconnectAttempts - 1).toInt()),
    );
    Future.delayed(delay, () {
      if (!_disposed) _connect();
    });
  }

  void _onDone() {
    if (_disposed || _status == TerminalStatus.exited) return;
    _onError(appL10n.webSocketClosed);
  }

  void _onOutput(String data) {
    if (_status != TerminalStatus.connected) {
      // A dead or idle session drops input as before; a reconnecting one
      // holds a bounded tail so keystrokes are not silently lost.
      if (_status == TerminalStatus.connecting ||
          _status == TerminalStatus.disconnected) {
        // Keep the most recent input: once the buffer is full the oldest
        // keystrokes are the least relevant to replay.
        if (_inputBuffer.length + data.length > _inputBufferLimit) {
          _inputBuffer.clear();
        }
        _inputBuffer.write(
          data.length > _inputBufferLimit
              ? data.substring(data.length - _inputBufferLimit)
              : data,
        );
      }
      return;
    }
    _send(jsonEncode({'type': 'input', 'data': data}));
  }

  void _flushInputBuffer() {
    if (_inputBuffer.isEmpty) return;
    final pending = _inputBuffer.toString();
    _inputBuffer.clear();
    _send(jsonEncode({'type': 'input', 'data': pending}));
  }

  void _onResize(int w, int h, int pw, int ph) => _sendResize(w, h);

  void _sendResize(int cols, int rows) {
    _send(jsonEncode({'type': 'resize', 'cols': cols, 'rows': rows}));
  }

  void _send(String data) {
    if (_disposed) return;
    if (_channel != null && _status == TerminalStatus.connected) {
      _channel!.sink.add(data);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _stabilityTimer?.cancel();
    _sub?.cancel();
    _channel?.sink.close();
    _utf8Sink?.close();
    super.dispose();
  }
}

/// Delivers each decoded text chunk to the terminal as it completes; a
/// [StringConversionSink.withCallback] would accumulate until close.
class _TerminalTextSink implements Sink<String> {
  _TerminalTextSink(this._write);

  final void Function(String) _write;

  @override
  void add(String data) {
    if (data.isNotEmpty) _write(data);
  }

  @override
  void close() {}
}

/// Factory signature for creating a [TerminalSession].
///
/// This is the default factory used by [TerminalStore] so tests can inject a
/// fake session without starting a real PTY or WebSocket. [threadId] is the
/// currently active thread, if any — remote sessions may be created without
/// one since the terminal workspace is global.
///
/// Non-test callers should pass [createTerminalSession] and let it handle the
/// actual local/remote backend.
typedef TerminalSessionFactory =
    Future<TerminalSession> Function({
      required ApiService api,
      required String? threadId,
      required bool local,
      String? workingDir,
    });

/// Create a local or remote terminal session. [workingDir] only applies to
/// local sessions — remote shells start in the thread's working directory,
/// resolved by the backend from [threadId].
Future<TerminalSession> createTerminalSession({
  required ApiService api,
  required String? threadId,
  required bool local,
  String? workingDir,
}) async {
  if (local) {
    return LocalTerminalSession(
      id: 'local-${DateTime.now().millisecondsSinceEpoch}',
      workingDir: workingDir,
    );
  }
  final sessionId = await api.createTerminalSession(threadId);
  final uri = await api.terminalWebSocketUri(sessionId);
  final token = await api.terminalToken;
  return RemoteTerminalSession(id: sessionId, uri: uri, token: token);
}
