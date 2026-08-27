import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Connect a native WebSocket with a bearer token header.
WebSocketChannel connectTerminalWebSocketImpl(Uri uri, {String? token}) {
  final headers = <String, String>{};
  if (token != null && token.isNotEmpty) {
    headers['Authorization'] = 'Bearer $token';
  }
  return IOWebSocketChannel.connect(uri, headers: headers);
}
