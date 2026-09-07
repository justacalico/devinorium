import 'dart:io';

import 'package:pty2/pty2.dart';
import 'package:xterm/xterm.dart';

import '../l10n/global_l10n.dart';

/// Desktop PTY backend using the `pty2` package.
class LocalPtyBackend {
  LocalPtyBackend(this.terminal);

  final Terminal terminal;
  PseudoTerminal? _pty;

  void start() {
    final shell = Platform.isWindows ? 'pwsh.exe' : 'bash';
    try {
      _pty = PseudoTerminal.start(
        shell,
        const <String>[],
        environment: Platform.environment,
        raw: false,
      );
      _pty!.out.listen(
        terminal.write,
        onError: (Object e) =>
            terminal.write('\r\n${appL10n.terminalPtyError('$e')}\r\n'),
        onDone: () => terminal.write('\r\n${appL10n.terminalPtyClosed}\r\n'),
      );
      _pty!.exitCode.then((code) {
        terminal.write('\r\n${appL10n.terminalProcessExited('$code')}\r\n');
      });
    } catch (e) {
      terminal.write(
        '\r\n${appL10n.terminalShellStartFailed(shell, '$e')}\r\n',
      );
    }
  }

  void write(String data) => _pty?.write(data);

  void resize(int cols, int rows) => _pty?.resize(cols, rows);

  void dispose() {
    _pty?.kill();
  }
}
