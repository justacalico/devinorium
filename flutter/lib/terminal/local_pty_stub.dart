import 'package:xterm/xterm.dart';

/// Stub backend for platforms that cannot run a local PTY (web, mobile).
class LocalPtyBackend {
  LocalPtyBackend(this.terminal);

  final Terminal terminal;

  void start() {
    terminal.write('Local terminal is only available on desktop.\r\n');
  }

  void write(String data) {}

  void resize(int cols, int rows) {}

  void dispose() {}
}
