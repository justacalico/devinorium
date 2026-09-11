import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/l10n.dart';
import '../../state/app_state.dart';
import '../thread_page.dart';

class AgentPanel extends StatelessWidget {
  const AgentPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = context.read<AppState>();
    final terminalStore = state.terminalStore;

    return ListenableBuilder(
      listenable: terminalStore,
      builder: (context, _) {
        return Material(
          color: theme.colorScheme.surfaceContainerLow,
          child: Column(
            children: [
              _Header(
                onClose: () => state.setAgentPanelOpen(false),
                onToggleTerminal: terminalStore.toggleOpen,
                terminalOpen: terminalStore.open,
              ),
              const Divider(height: 1),
              const Expanded(child: ChatView()),
            ],
          ),
        );
      },
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
    final theme = Theme.of(context);

    return Selector<AppState, String?>(
      selector: (_, s) => s.activeThreadDetail?.thread.title,
      builder: (context, title, _) {
        final displayTitle = title ?? l10n(context).selectOrCreateThread;

        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  displayTitle,
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
      },
    );
  }
}
