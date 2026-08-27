import 'package:flutter/material.dart';

import 'terminal_session.dart';
import 'terminal_view.dart';

/// Displays one or more [TerminalSession] tiles in a responsive grid.
class TerminalGrid extends StatelessWidget {
  const TerminalGrid({
    super.key,
    required this.sessions,
    required this.onClose,
  });

  final List<TerminalSession> sessions;
  final ValueChanged<TerminalSession> onClose;

  @override
  Widget build(BuildContext context) {
    if (sessions.isEmpty) {
      return const Center(child: Text('No terminal sessions'));
    }

    if (sessions.length == 1) {
      return _TerminalTile(
        session: sessions.first,
        onClose: onClose,
      );
    }

    return GridView.builder(
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 4 / 3,
      ),
      itemCount: sessions.length,
      itemBuilder: (context, index) {
        final session = sessions[index];
        return _TerminalTile(
          session: session,
          onClose: onClose,
          autofocus: index == 0,
        );
      },
    );
  }
}

class _TerminalTile extends StatelessWidget {
  const _TerminalTile({
    required this.session,
    required this.onClose,
    this.autofocus = true,
  });

  final TerminalSession session;
  final ValueChanged<TerminalSession> onClose;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(4),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Stack(
          children: [
            Positioned.fill(
              child: TerminalViewWidget(
                session: session,
                autofocus: autofocus,
              ),
            ),
            Positioned(
              top: 0,
              right: 4,
              child: IconButton(
                style: IconButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(32, 32),
                ),
                icon: const Icon(Icons.close, size: 18),
                onPressed: () => onClose(session),
                tooltip: 'Close terminal',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
