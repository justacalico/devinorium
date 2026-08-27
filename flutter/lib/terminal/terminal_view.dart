import 'package:flutter/material.dart';
import 'package:xterm/ui.dart';
import 'package:xterm/xterm.dart';

import 'terminal_session.dart';

/// Renders a [TerminalSession] using `xterm`.
class TerminalViewWidget extends StatefulWidget {
  const TerminalViewWidget({
    super.key,
    required this.session,
    this.autofocus = true,
  });

  final TerminalSession session;
  final bool autofocus;

  @override
  State<TerminalViewWidget> createState() => _TerminalViewWidgetState();
}

class _TerminalViewWidgetState extends State<TerminalViewWidget> {
  late final _controller = TerminalController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
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

    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final status = session.status;
        final statusText = switch (status) {
          TerminalStatus.connecting => 'connecting',
          TerminalStatus.connected => 'connected',
          TerminalStatus.disconnected => 'disconnected',
          TerminalStatus.exited => 'exited',
          TerminalStatus.idle => 'idle',
        };

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
              const Spacer(),
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: _statusColor(status, colorScheme),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 4),
              Text(
                statusText,
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ],
          ),
        );
      },
    );
  }

  Color _statusColor(TerminalStatus status, ColorScheme scheme) {
    return switch (status) {
      TerminalStatus.connecting => Colors.orange,
      TerminalStatus.connected => Colors.green,
      TerminalStatus.disconnected => Colors.red,
      TerminalStatus.exited => scheme.outline,
      TerminalStatus.idle => scheme.primary,
    };
  }
}
