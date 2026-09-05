import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../l10n/l10n.dart';
import '../../state/app_state.dart';

class EditorTabBar extends StatelessWidget {
  const EditorTabBar({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = context.read<AppState>();

    return Selector<AppState, ({
      List<EditorTab> tabs,
      String? activePath,
      bool activeTabLoading,
      bool activeTabSaving,
      bool activeTabDirty,
      String? activeThreadId,
      bool editorTerminalOpen,
    })>(
      selector: (_, s) {
        final activeTab = s.activeEditorTab;
        return (
          tabs: s.editorTabs,
          activePath: s.activeEditorPath,
          activeTabLoading: activeTab?.loading ?? false,
          activeTabSaving: activeTab?.saving ?? false,
          activeTabDirty: activeTab?.dirty ?? false,
          activeThreadId: s.activeThreadId,
          editorTerminalOpen: s.editorTerminalOpen,
        );
      },
      builder: (context, model, _) {
        final activePath = model.activePath;
        return Container(
          color: theme.colorScheme.surfaceContainerLow,
          height: 40,
          child: Row(
            children: [
              Expanded(
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (final tab in model.tabs)
                      _Tab(
                        tab: tab,
                        active: activePath == tab.path,
                      ),
                  ],
                ),
              ),
              if (model.activeThreadId != null)
                _ToolbarButton(
                  icon: model.editorTerminalOpen
                      ? Icons.terminal
                      : Icons.terminal_outlined,
                  tooltip: l10n(context).terminal,
                  onPressed: () =>
                      state.setEditorTerminalOpen(!model.editorTerminalOpen),
                ),
              if (activePath != null) ...[
                _ToolbarButton(
                  icon: Icons.refresh,
                  tooltip: l10n(context).editorReload,
                  onPressed: model.activeTabLoading ||
                          model.activeTabSaving ||
                          model.activeTabDirty
                      ? null
                      : () => state.reloadEditorTab(activePath),
                ),
                _ToolbarButton(
                  icon: model.activeTabSaving
                      ? Icons.pending_outlined
                      : Icons.save_outlined,
                  tooltip: l10n(context).save,
                  onPressed: model.activeTabDirty && !model.activeTabSaving
                      ? () => state.saveEditorTab(activePath)
                      : null,
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _ToolbarButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  const _ToolbarButton({
    required this.icon,
    required this.tooltip,
    this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, size: 18),
      tooltip: tooltip,
      onPressed: onPressed,
      visualDensity: VisualDensity.compact,
    );
  }
}

class _Tab extends StatelessWidget {
  final EditorTab tab;
  final bool active;

  const _Tab({required this.tab, required this.active});

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final theme = Theme.of(context);
    final label = p.basename(tab.path);

    return GestureDetector(
      onTap: () => state.setActiveEditorPath(tab.path),
      onSecondaryTap: () => _maybeClose(context, state, tab),
      onTertiaryTapUp: (_) => _maybeClose(context, state, tab),
      child: Container(
        constraints: const BoxConstraints(minWidth: 80, maxWidth: 180),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: active
              ? theme.colorScheme.surface
              : theme.colorScheme.surfaceContainerLow,
          border: Border(
            bottom: BorderSide(
              color: active ? theme.colorScheme.primary : Colors.transparent,
              width: 2,
            ),
            right: BorderSide(color: theme.colorScheme.outlineVariant),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Expanded(
              child: Text(
                '${tab.dirty ? "\u2022 " : ""}$label',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: active ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ),
            if (tab.saving || tab.loading)
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              InkWell(
                onTap: () => _maybeClose(context, state, tab),
                child: const Icon(Icons.close, size: 14),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _maybeClose(BuildContext context, AppState state, tab) async {
    if (tab.saving || tab.loading) return;
    if (!tab.dirty) {
      state.closeEditorTab(tab.path);
      return;
    }
    final l = l10n(context);
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l.editorUnsavedChanges),
        content: Text(l.editorSaveBeforeClose(tab.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l.editorDiscard),
          ),
          TextButton(
            onPressed: () async {
              Navigator.of(dialogContext).pop(false);
              await state.saveEditorTab(tab.path);
              if (state.activeEditorTab?.dirty == false) {
                state.closeEditorTab(tab.path);
              }
            },
            child: Text(l.save),
          ),
        ],
      ),
    );
    if (result == true) {
      state.closeEditorTab(tab.path);
    }
  }
}
