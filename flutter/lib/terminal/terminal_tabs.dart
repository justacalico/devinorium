import 'package:flutter/material.dart';

import 'terminal_session.dart';
import 'terminal_view.dart';

/// Displays one or more [TerminalSession] tabs like a browser tab bar, with
/// the active session shown below.
class TerminalTabs extends StatelessWidget {
  const TerminalTabs({
    super.key,
    required this.sessions,
    required this.activeIndex,
    required this.onActiveIndexChanged,
    required this.onClose,
  });

  final List<TerminalSession> sessions;
  final int activeIndex;
  final ValueChanged<int> onActiveIndexChanged;
  final ValueChanged<TerminalSession> onClose;

  @override
  Widget build(BuildContext context) {
    if (sessions.isEmpty) {
      return const Center(child: Text('No terminal sessions'));
    }

    final index = activeIndex.clamp(0, sessions.length - 1);
    final session = sessions[index];

    return Column(
      children: [
        _TabBar(
          sessions: sessions,
          activeIndex: index,
          onTap: onActiveIndexChanged,
          onClose: onClose,
        ),
        Expanded(
          child: TerminalViewWidget(
            session: session,
            autofocus: true,
          ),
        ),
      ],
    );
  }
}

class _TabBar extends StatelessWidget {
  const _TabBar({
    required this.sessions,
    required this.activeIndex,
    required this.onTap,
    required this.onClose,
  });

  final List<TerminalSession> sessions;
  final int activeIndex;
  final ValueChanged<int> onTap;
  final ValueChanged<TerminalSession> onClose;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      height: 36,
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: Border(
          bottom: BorderSide(color: colorScheme.outlineVariant),
        ),
      ),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: sessions.length,
        itemBuilder: (context, index) {
          final session = sessions[index];
          return _Tab(
            session: session,
            active: index == activeIndex,
            onTap: () => onTap(index),
            onClose: () => onClose(session),
          );
        },
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({
    required this.session,
    required this.active,
    required this.onTap,
    required this.onClose,
  });

  final TerminalSession session;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final background =
        active ? colorScheme.primaryContainer : colorScheme.surface;
    final foreground =
        active ? colorScheme.onPrimaryContainer : colorScheme.onSurfaceVariant;

    return InkWell(
      onTap: onTap,
      child: Container(
        width: 160,
        color: background,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            Icon(
              session.isLocal ? Icons.terminal : Icons.cloud,
              size: 14,
              color: foreground,
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                session.id,
                style: Theme.of(context)
                    .textTheme
                    .labelMedium
                    ?.copyWith(color: foreground),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              style: IconButton.styleFrom(
                padding: EdgeInsets.zero,
                minimumSize: const Size(20, 20),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              icon: Icon(Icons.close, size: 14, color: foreground),
              onPressed: onClose,
              tooltip: 'Close tab',
            ),
          ],
        ),
      ),
    );
  }
}
