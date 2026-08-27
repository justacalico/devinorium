import 'package:web_socket_channel/web_socket_channel.dart';

/// Stub implementation for unsupported platforms (should not be called).
WebSocketChannel connectTerminalWebSocketImpl(Uri uri, {String? token}) {
  throw UnsupportedError('Terminal WebSocket not supported on this platform');
}
