import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/ui.dart';
import 'package:xterm/xterm.dart';

import 'terminal_session.dart';

/// Renders a [TerminalSession] using `xterm`.
class TerminalViewWidget extends StatefulWidget {
  const TerminalViewWidget({
    super.key,
    required this.session,
    this.autofocus = true,
    this.controller,
  });

  final TerminalSession session;
  final bool autofocus;
  final TerminalController? controller;

  @override
  State<TerminalViewWidget> createState() => _TerminalViewWidgetState();
}

class _TerminalViewWidgetState extends State<TerminalViewWidget> {
  late TerminalController _controller;

  @override
  void initState() {
    super.initState();
    _controller = widget.controller ?? TerminalController();
  }

  @override
  void didUpdateWidget(TerminalViewWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      if (oldWidget.controller == null) {
        _controller.dispose();
      }
      _controller = widget.controller ?? TerminalController();
    }
  }

  @override
  void dispose() {
    if (widget.controller == null) {
      _controller.dispose();
    }
    super.dispose();
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }

    final keyboard = HardwareKeyboard.instance;
    if (!keyboard.isControlPressed ||
        !keyboard.isShiftPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed) {
      return KeyEventResult.ignored;
    }

    if (event.logicalKey == LogicalKeyboardKey.keyC) {
      unawaited(_copySelection());
      return KeyEventResult.handled;
    }

    if (event.logicalKey == LogicalKeyboardKey.keyV) {
      unawaited(_pasteFromClipboard());
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  Future<void> _copySelection() async {
    try {
      final selection = _controller.selection;
      if (selection == null) {
        return;
      }

      final text = widget.session.terminal.buffer.getText(selection);
      if (text.isEmpty) {
        return;
      }

      if (!mounted) {
        return;
      }

      await Clipboard.setData(ClipboardData(text: text));
    } on Exception {
      // Ignore clipboard failures (e.g., permission denied on web).
    }
  }

  Future<void> _pasteFromClipboard() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text;
      if (text == null || text.isEmpty) {
        return;
      }

      if (!mounted) {
        return;
      }

      widget.session.terminal.paste(text);
      _controller.clearSelection();
    } on Exception {
      // Ignore clipboard failures (e.g., permission denied on web).
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      color: colorScheme.surface,
      child: Column(
        children: [
          _TerminalToolbar(session: widget.session),
          Expanded(
            child: TerminalView(
              widget.session.terminal,
              controller: _controller,
              autofocus: widget.autofocus,
              padding: const EdgeInsets.all(4),
              backgroundOpacity: 1,
              onKeyEvent: _handleKeyEvent,
            ),
          ),
        ],
      ),
    );
  }
}

class _TerminalToolbar extends StatelessWidget {
  const _TerminalToolbar({required this.session});

  final TerminalSession session;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      color: colorScheme.surface,
      child: Row(
        children: [
          Icon(
            session.isLocal ? Icons.terminal : Icons.cloud,
            size: 16,
            color: colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Text(
            session.id,
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ],
      ),
    );
  }
}
