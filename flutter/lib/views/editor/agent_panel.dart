import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/l10n.dart';
import '../../state/app_state.dart';
import '../../terminal/thread_terminal_panel.dart';
import '../thread_page.dart';

class AgentPanel extends StatefulWidget {
  const AgentPanel({super.key});

  @override
  State<AgentPanel> createState() => _AgentPanelState();
}

class _AgentPanelState extends State<AgentPanel> {
  bool _terminalOpen = true;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final threadId = state.activeThreadId;

    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      child: Column(
        children: [
          _Header(
            onClose: () => state.setAgentPanelOpen(false),
            onToggleTerminal: () =>
                setState(() => _terminalOpen = !_terminalOpen),
            terminalOpen: _terminalOpen,
          ),
          const Divider(height: 1),
          const Expanded(child: ChatView()),
          if (threadId != null && _terminalOpen)
            ThreadTerminalPanel(
              api: state.api,
              threadId: threadId,
              onClose: () => setState(() => _terminalOpen = false),
            ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final VoidCallback onClose;
  final VoidCallback onToggleTerminal;
  final bool terminalOpen;

  const _Header({
    required this.onClose,
    required this.onToggleTerminal,
    required this.terminalOpen,
  });

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final thread = state.activeThreadDetail;
    final title = thread?.thread.title ?? l10n(context).selectOrCreateThread;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall,
            ),
          ),
          IconButton(
            tooltip: l10n(context).terminal,
            icon: Icon(
              terminalOpen ? Icons.terminal : Icons.terminal_outlined,
              size: 20,
            ),
            onPressed: onToggleTerminal,
          ),
          IconButton(
            tooltip: l10n(context).close,
            icon: const Icon(Icons.close, size: 20),
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}
