import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/api_service.dart';
import '../../l10n/l10n.dart';
import '../../state/app_state.dart';
import '../../terminal/thread_terminal_panel.dart';
import 'agent_panel.dart';
import 'editor_tab_bar.dart';
import 'file_editor.dart';

const _wideThreshold = 960.0;

class EditorPage extends StatefulWidget {
  const EditorPage({super.key});

  @override
  State<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<EditorPage> {
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= _wideThreshold;
        return isWide ? const _WideEditor() : const _NarrowEditor();
      },
    );
  }
}

class _WideEditor extends StatelessWidget {
  const _WideEditor();

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();

    return Selector<AppState, _EditorLayoutModel>(
      selector: (_, s) => (
        tabSaving: s.activeEditorTab?.saving == true,
        agentPanelOpen: s.agentPanelOpen,
        agentPanelUserSet: s.agentPanelUserSet,
        agentPanelWidth: s.editorAgentPanelWidth,
        terminalOpen: s.editorTerminalOpen && s.activeThreadId != null,
        activeThreadId: s.activeThreadId,
      ),
      builder: (context, model, _) {
        final agentPanelOpen =
            model.agentPanelUserSet ? model.agentPanelOpen : true;
        return Row(
          children: [
            Expanded(
              child: Column(
                children: [
                  const EditorTabBar(),
                  const Expanded(child: FileEditor()),
                  if (model.tabSaving)
                    const LinearProgressIndicator(minHeight: 2),
                  if (model.terminalOpen) const _EditorTerminal(),
                ],
              ),
            ),
            if (agentPanelOpen) ...[
              _ResizeHandle(
                onDrag: (delta) => state.setEditorAgentPanelWidth(
                    model.agentPanelWidth - delta),
              ),
              SizedBox(
                  width: model.agentPanelWidth, child: const AgentPanel()),
            ],
          ],
        );
      },
    );
  }
}

typedef _EditorLayoutModel = ({
  bool tabSaving,
  bool agentPanelOpen,
  bool agentPanelUserSet,
  double agentPanelWidth,
  bool terminalOpen,
  String? activeThreadId,
});

class _EditorTerminal extends StatelessWidget {
  const _EditorTerminal();

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();

    return Selector<AppState, ({
      String? activeThreadId,
      double editorTerminalHeight,
      ApiService api,
    })>(
      selector: (_, s) => (
        activeThreadId: s.activeThreadId,
        editorTerminalHeight: s.editorTerminalHeight,
        api: s.api,
      ),
      builder: (context, model, _) {
        final threadId = model.activeThreadId;
        if (threadId == null) return const SizedBox.shrink();

        return ThreadTerminalPanel(
          api: model.api,
          threadId: threadId,
          initialHeight: model.editorTerminalHeight,
          onHeightChanged: state.setEditorTerminalHeight,
          onClose: () => state.setEditorTerminalOpen(false),
        );
      },
    );
  }
}

class _NarrowEditor extends StatelessWidget {
  const _NarrowEditor();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = context.read<AppState>();
    final maxWidth = MediaQuery.of(context).size.width;

    return Selector<AppState, _EditorLayoutModel>(
      selector: (_, s) => (
        tabSaving: s.activeEditorTab?.saving == true,
        agentPanelOpen: s.agentPanelOpen,
        agentPanelUserSet: s.agentPanelUserSet,
        agentPanelWidth: s.editorAgentPanelWidth,
        terminalOpen: s.editorTerminalOpen && s.activeThreadId != null,
        activeThreadId: s.activeThreadId,
      ),
      builder: (context, model, _) {
        // Until the user opens or closes the panel explicitly, let it follow
        // the layout: open in the wide layout, closed in the narrow one.
        final agentPanelOpen =
            model.agentPanelUserSet ? model.agentPanelOpen : false;
        return Stack(
          children: [
            Column(
              children: [
                const EditorTabBar(),
                const Expanded(child: FileEditor()),
                if (model.tabSaving)
                  const LinearProgressIndicator(minHeight: 2),
                if (model.terminalOpen) const _EditorTerminal(),
              ],
            ),
            if (agentPanelOpen)
              Positioned.fill(
                child: GestureDetector(
                  onTap: () => state.setAgentPanelOpen(false),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    color: Colors.black38,
                  ),
                ),
              ),
            Positioned(
              top: 48,
              left: 8,
              child: _FloatingToggle(
                icon: Icons.folder_outlined,
                tooltip: l10n(context).files,
                onPressed: () {
                  unawaited(state.openFilesPanel());
                  state.openSidebar();
                },
              ),
            ),
            Positioned(
              top: 48,
              right: 8,
              child: _FloatingToggle(
                icon: agentPanelOpen ? Icons.close : Icons.chat_outlined,
                tooltip:
                    agentPanelOpen ? l10n(context).close : l10n(context).chat,
                onPressed: () =>
                    state.setAgentPanelOpen(!agentPanelOpen),
              ),
            ),
            if (agentPanelOpen)
              AnimatedPositioned(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
                right: 0,
                top: 0,
                bottom: 0,
                width: model.agentPanelWidth.clamp(0, maxWidth * 0.9),
                child: Material(
                  elevation: 4,
                  color: theme.colorScheme.surface,
                  child: const AgentPanel(),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _FloatingToggle extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  const _FloatingToggle({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Material(
      color: theme.colorScheme.surface,
      elevation: 2,
      borderRadius: BorderRadius.circular(8),
      child: IconButton(
        tooltip: tooltip,
        icon: Icon(icon),
        onPressed: onPressed,
      ),
    );
  }
}

class _ResizeHandle extends StatelessWidget {
  final ValueChanged<double> onDrag;

  const _ResizeHandle({required this.onDrag});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragUpdate: (details) => onDrag(details.delta.dx),
        child: Container(
          width: 10,
          color: theme.colorScheme.outlineVariant.withAlpha(40),
          alignment: Alignment.center,
          child: VerticalDivider(
            width: 2,
            color: theme.colorScheme.outline,
          ),
        ),
      ),
    );
  }
}
