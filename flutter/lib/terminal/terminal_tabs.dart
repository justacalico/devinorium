import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import 'terminal_grid.dart';
import 'terminal_session.dart';
import 'terminal_store.dart';

/// Displays one or more workspace [TerminalTab]s like a browser tab bar, with
/// the active tab's terminal grid shown below.
class TerminalTabs extends StatelessWidget {
  const TerminalTabs({
    super.key,
    required this.tabs,
    required this.activeTabIndex,
    required this.onTabChanged,
    required this.onAddTab,
    required this.onCloseSession,
    required this.onCloseTab,
    required this.onRenameTab,
  });

  final List<TerminalTab> tabs;
  final int activeTabIndex;
  final ValueChanged<int> onTabChanged;
  final VoidCallback onAddTab;
  final ValueChanged<TerminalSession> onCloseSession;
  final ValueChanged<TerminalTab> onCloseTab;
  final ValueChanged<TerminalTab> onRenameTab;

  @override
  Widget build(BuildContext context) {
    final index = tabs.isEmpty ? 0 : activeTabIndex.clamp(0, tabs.length - 1);
    final tab = tabs.isEmpty ? null : tabs[index];

    return Column(
      children: [
        _TabBar(
          tabs: tabs,
          activeIndex: index,
          onTap: onTabChanged,
          onClose: onCloseTab,
          onAddTab: onAddTab,
          onRename: onRenameTab,
        ),
        Expanded(
          child: tab == null
              ? Center(child: Text(l10n(context).terminalNoSessions))
              : TerminalGrid(sessions: tab.sessions, onClose: onCloseSession),
        ),
      ],
    );
  }
}

class _TabBar extends StatelessWidget {
  const _TabBar({
    required this.tabs,
    required this.activeIndex,
    required this.onTap,
    required this.onClose,
    required this.onAddTab,
    required this.onRename,
  });

  final List<TerminalTab> tabs;
  final int activeIndex;
  final ValueChanged<int> onTap;
  final ValueChanged<TerminalTab> onClose;
  final VoidCallback onAddTab;
  final ValueChanged<TerminalTab> onRename;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      height: 36,
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: Border(bottom: BorderSide(color: colorScheme.outlineVariant)),
      ),
      child: Row(
        children: [
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: tabs.length,
              itemBuilder: (context, index) {
                final tab = tabs[index];
                return _Tab(
                  index: index,
                  tab: tab,
                  active: index == activeIndex,
                  onTap: () => onTap(index),
                  onClose: () => onClose(tab),
                  onRename: () => onRename(tab),
                );
              },
            ),
          ),
          _AddTabButton(onTap: onAddTab),
        ],
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({
    required this.index,
    required this.tab,
    required this.active,
    required this.onTap,
    required this.onClose,
    required this.onRename,
  });

  final int index;
  final TerminalTab tab;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onClose;
  final VoidCallback onRename;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final background = active
        ? colorScheme.primaryContainer
        : colorScheme.surface;
    final foreground = active
        ? colorScheme.onPrimaryContainer
        : colorScheme.onSurfaceVariant;

    return InkWell(
      onTap: onTap,
      onSecondaryTap: onRename,
      onLongPress: onRename,
      child: Container(
        width: 140,
        color: background,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                tab.name ?? l10n(context).terminalTab(index + 1),
                style: Theme.of(
                  context,
                ).textTheme.labelMedium?.copyWith(color: foreground),
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
              tooltip: l10n(context).terminalCloseTab,
            ),
          ],
        ),
      ),
    );
  }
}

class _AddTabButton extends StatelessWidget {
  const _AddTabButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return IconButton(
      key: const ValueKey('addTerminalTab'),
      style: IconButton.styleFrom(
        padding: EdgeInsets.zero,
        minimumSize: const Size(36, 36),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      icon: Icon(Icons.add, size: 18, color: colorScheme.onSurfaceVariant),
      onPressed: onTap,
      tooltip: l10n(context).terminalNewTab,
    );
  }
}
