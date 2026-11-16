import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../terminal/web_socket_factory.dart';

/// One agent-browser snapshot: the latest viewport JPEG plus the page
/// chrome shown above it. `frame` stays `null` until the first image
/// arrives so the panel can show its empty state.
class BrowserFrame {
  const BrowserFrame({this.frame, this.url = '', this.title = ''});

  final Uint8List? frame;
  final String url;
  final String title;

  BrowserFrame merge(BrowserFrame next) {
    return BrowserFrame(
      frame: next.frame ?? frame,
      url: next.url.isNotEmpty ? next.url : url,
      title: next.title.isNotEmpty ? next.title : title,
    );
  }
}

enum BrowserFeedStatus { connecting, live, idle, closed }

/// Socket client for one thread's agent-browser feed.
///
/// The feed is strictly server-to-client: frames arrive as
/// `{"type":"frame","url","title","data":<base64 jpeg>}` text messages and
/// `{"type":"status","state":"idle"}` marks "no browser session yet". The
/// panel renders whatever arrives; nothing is ever sent back, keeping the
/// remote browser view-only.
class BrowserFeedClient extends ChangeNotifier {
  BrowserFeedClient({
    required this.uri,
    this.token,
    WebSocketChannel Function(Uri, {String? token})? connector,
  }) : _connector = connector ?? connectTerminalWebSocket {
    _connect();
  }

  final Uri uri;
  final String? token;

  final WebSocketChannel Function(Uri, {String? token}) _connector;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  Timer? _reconnectTimer;
  Timer? _stabilityTimer;
  int _reconnectAttempts = 0;
  bool _disposed = false;

  static const _maxReconnectAttempts = 5;
  static const _stableWindow = Duration(seconds: 10);
  static const _retryDelay = Duration(seconds: 2);

  BrowserFeedStatus _status = BrowserFeedStatus.connecting;
  BrowserFrame _frame = const BrowserFrame();

  BrowserFeedStatus get status => _status;
  BrowserFrame get frame => _frame;

  bool _reconnectScheduled = false;

  void _connect() {
    if (_disposed) return;
    _reconnectScheduled = false;
    _status = BrowserFeedStatus.connecting;
    notifyListeners();
    try {
      _channel = _connector(uri, token: token);
    } catch (_) {
      _scheduleReconnect();
      return;
    }
    _stabilityTimer?.cancel();
    _stabilityTimer = Timer(_stableWindow, () {
      _reconnectAttempts = 0;
    });
    _sub = _channel!.stream.listen(
      _onMessage,
      onDone: _scheduleReconnect,
      onError: (_) => _scheduleReconnect(),
      cancelOnError: false,
    );
  }

  void _onMessage(dynamic raw) {
    if (raw is! String) return;
    final Map<String, dynamic> msg;
    try {
      msg = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    switch (msg['type']) {
      case 'frame':
        Uint8List? image;
        final data = msg['data'];
        if (data is String && data.isNotEmpty) {
          try {
            image = base64Decode(data);
          } catch (_) {
            image = null;
          }
        }
        final url = msg['url'];
        final title = msg['title'];
        _frame = _frame.merge(
          BrowserFrame(
            frame: image,
            url: url is String ? url : '',
            title: title is String ? title : '',
          ),
        );
        _status = BrowserFeedStatus.live;
        notifyListeners();
      case 'status':
        if (msg['state'] == 'idle' && _frame.frame == null) {
          _status = BrowserFeedStatus.idle;
          notifyListeners();
        }
    }
  }

  void _scheduleReconnect() {
    // onError is usually followed by onDone for the same dead socket;
    // the first call wins so one failure costs one retry.
    if (_disposed || _reconnectScheduled) return;
    _reconnectScheduled = true;
    _stabilityTimer?.cancel();
    _sub?.cancel();
    _sub = null;
    _channel = null;
    if (_reconnectAttempts >= _maxReconnectAttempts) {
      _status = BrowserFeedStatus.closed;
      notifyListeners();
      return;
    }
    _reconnectAttempts++;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(_retryDelay, _connect);
  }

  @override
  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _stabilityTimer?.cancel();
    _sub?.cancel();
    _channel?.sink.close();
    super.dispose();
  }
}
