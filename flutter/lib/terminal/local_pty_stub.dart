import 'package:xterm/xterm.dart';

import '../l10n/global_l10n.dart';

/// Stub backend for platforms that cannot run a local PTY (web, mobile).
class LocalPtyBackend {
  LocalPtyBackend(this.terminal);

  final Terminal terminal;

  void start() {
    terminal.write('${appL10n.terminalLocalOnlyDesktop}\r\n');
  }

  void write(String data) {}

  void resize(int cols, int rows) {}

  void dispose() {}
}
