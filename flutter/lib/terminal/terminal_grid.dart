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

    final crossAxisCount = sessions.length == 1 ? 1 : 2;

    return GridView.builder(
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        childAspectRatio: sessions.length == 1 ? 16 / 9 : 4 / 3,
      ),
      itemCount: sessions.length,
      itemBuilder: (context, index) {
        final session = sessions[index];
        return Padding(
          padding: const EdgeInsets.all(4),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Stack(
              children: [
                Positioned.fill(
                  child: TerminalViewWidget(
                    session: session,
                    autofocus: index == 0,
                  ),
                ),
                Positioned(
                  top: 4,
                  right: 4,
                  child: IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => onClose(session),
                    tooltip: 'Close terminal',
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
