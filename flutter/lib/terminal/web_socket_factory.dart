import 'package:web_socket_channel/web_socket_channel.dart';

import 'web_socket_factory_stub.dart'
    if (dart.library.html) 'web_socket_factory_web.dart'
    if (dart.library.io) 'web_socket_factory_io.dart';

/// Open an authenticated terminal WebSocket.
///
/// Native clients pass the bearer token as a header; web clients rely on the
/// session cookie with `withCredentials` enabled.
WebSocketChannel connectTerminalWebSocket(Uri uri, {String? token}) {
  return connectTerminalWebSocketImpl(uri, token: token);
}
