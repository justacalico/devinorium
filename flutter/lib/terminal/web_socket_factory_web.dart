import 'package:web_socket_channel/html.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Connect a browser WebSocket. The session cookie is sent automatically when
/// the Flutter app is served from the same origin as the backend.
WebSocketChannel connectTerminalWebSocketImpl(Uri uri, {String? token}) {
  return HtmlWebSocketChannel.connect(uri.toString());
}
