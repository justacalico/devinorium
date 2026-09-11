import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import 'terminal_session.dart';
import 'terminal_store.dart';
import 'terminal_tabs.dart';

/// A resizable bottom panel hosting the global terminal workspace.
///
/// Sessions live in [TerminalStore], so the panel is a thin view: it can be
/// unmounted and remounted (switching between the agents and editor views,
/// changing threads) without losing any terminal state.
class TerminalPanel extends StatelessWidget {
  const TerminalPanel({super.key, required this.store, this.onClose});

  final TerminalStore store;

  /// Called when the user hides the panel. Defaults to closing the store.
  final VoidCallback? onClose;

  static const _maxHeightRatio = 0.75;

  bool get _canUseLocalTerminal =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.windows);

  Future<void> _addSession(BuildContext context, {required bool local}) async {
    try {
      await store.addSession(local: local);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n(context).terminalStartFailed('$e'))),
        );
      }
    }
  }

  Future<void> _confirmCloseSession(
    BuildContext context,
    TerminalSession session,
  ) async {
    if (session.isBlank) {
      store.removeSession(session);
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n(context).terminalCloseTitle),
        content: Text(l10n(context).terminalCloseBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n(context).cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n(context).close),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      store.removeSession(session);
    }
  }

  Future<void> _confirmCloseTab(BuildContext context, TerminalTab tab) async {
    final nonBlankCount = tab.sessions.where((s) => !s.isBlank).length;
    if (nonBlankCount == 0) {
      store.removeTab(tab);
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n(context).terminalTabCloseTitle),
        content: Text(l10n(context).terminalTabCloseBody(nonBlankCount)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n(context).cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n(context).close),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      store.removeTab(tab);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        if (!store.open) return const SizedBox.shrink();

        return LayoutBuilder(
          builder: (context, constraints) {
            // The panel sits in a Column, so the parent constraint is
            // unbounded — cap by the window height instead.
            final maxHeight = math.min(
              MediaQuery.sizeOf(context).height * _maxHeightRatio,
              constraints.maxHeight,
            );
            final minHeight = math.min(TerminalStore.minHeight, maxHeight);
            final height = store.height.clamp(minHeight, maxHeight);

            return SizedBox(
              height: height,
              child: Column(
                children: [
                  _DragHandle(
                    onDragUpdate: (delta) => store.setHeight(
                      (store.height - delta).clamp(minHeight, maxHeight),
                    ),
                  ),
                  _Header(
                    title: l10n(context).terminal,
                    local: _canUseLocalTerminal,
                    busy: store.busy,
                    onAddLocal: _canUseLocalTerminal
                        ? () => _addSession(context, local: true)
                        : null,
                    onAddRemote: () => _addSession(context, local: false),
                    onClose: onClose ?? () => store.setOpen(false),
                  ),
                  Expanded(
                    child: TerminalTabs(
                      tabs: store.tabs,
                      activeTabIndex: store.activeTabIndex,
                      onTabChanged: store.setActiveTab,
                      onAddTab: store.addTab,
                      onCloseSession: (s) => _confirmCloseSession(context, s),
                      onCloseTab: (t) => _confirmCloseTab(context, t),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class _DragHandle extends StatelessWidget {
  const _DragHandle({required this.onDragUpdate});

  final ValueChanged<double> onDragUpdate;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return GestureDetector(
      key: const ValueKey('terminalDragHandle'),
      behavior: HitTestBehavior.translucent,
      onVerticalDragUpdate: (details) => onDragUpdate(details.delta.dy),
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeRow,
        child: Container(
          height: 8,
          color: colorScheme.surface,
          alignment: Alignment.center,
          child: Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: colorScheme.outline,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.title,
    required this.local,
    required this.busy,
    this.onAddLocal,
    required this.onAddRemote,
    this.onClose,
  });

  final String title;
  final bool local;
  final bool busy;
  final VoidCallback? onAddLocal;
  final VoidCallback onAddRemote;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      color: Theme.of(context).colorScheme.surface,
      child: Row(
        children: [
          Text(title, style: Theme.of(context).textTheme.titleSmall),
          const Spacer(),
          if (local)
            IconButton(
              key: const ValueKey('addLocalTerminal'),
              icon: const Icon(Icons.computer, size: 20),
              tooltip: l10n(context).terminalLocal,
              onPressed: busy ? null : onAddLocal,
            ),
          IconButton(
            key: const ValueKey('addRemoteTerminal'),
            icon: const Icon(Icons.cloud, size: 20),
            tooltip: l10n(context).terminalRemote,
            onPressed: busy ? null : onAddRemote,
          ),
          if (onClose != null)
            IconButton(
              icon: const Icon(Icons.keyboard_arrow_down, size: 20),
              tooltip: l10n(context).terminalHide,
              onPressed: onClose,
            ),
        ],
      ),
    );
  }
}
