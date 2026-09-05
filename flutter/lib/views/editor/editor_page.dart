import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/l10n.dart';
import '../../state/app_state.dart';
import '../../terminal/thread_terminal_panel.dart';
import '../files_panel.dart';
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
    final state = context.watch<AppState>();

    return Row(
      children: [
        if (state.editorFileTreeOpen) ...[
          SizedBox(width: state.editorTreeWidth, child: const FilesPanel()),
          _ResizeHandle(
            onDrag: (delta) =>
                state.setEditorTreeWidth(state.editorTreeWidth + delta),
          ),
        ],
        Expanded(
          child: Column(
            children: [
              const EditorTabBar(),
              const Expanded(child: FileEditor()),
              if (state.activeEditorTab?.saving == true)
                const LinearProgressIndicator(minHeight: 2),
              if (_terminalVisible(state)) const _EditorTerminal(),
            ],
          ),
        ),
        if (state.agentPanelOpen) ...[
          _ResizeHandle(
            onDrag: (delta) =>
                state.setEditorAgentPanelWidth(state.editorAgentPanelWidth - delta),
          ),
          SizedBox(width: state.editorAgentPanelWidth, child: const AgentPanel()),
        ],
      ],
    );
  }
}

bool _terminalVisible(AppState state) =>
    state.editorTerminalOpen && state.activeThreadId != null;

class _EditorTerminal extends StatelessWidget {
  const _EditorTerminal();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final threadId = state.activeThreadId;
    if (threadId == null) return const SizedBox.shrink();

    return ThreadTerminalPanel(
      api: state.api,
      threadId: threadId,
      initialHeight: state.editorTerminalHeight,
      onHeightChanged: state.setEditorTerminalHeight,
      onClose: () => state.setEditorTerminalOpen(false),
    );
  }
}

class _NarrowEditor extends StatelessWidget {
  const _NarrowEditor();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final showPanels = state.editorFileTreeOpen || state.agentPanelOpen;
    final maxWidth = MediaQuery.of(context).size.width;

    return Stack(
      children: [
        Column(
          children: [
            const EditorTabBar(),
            const Expanded(child: FileEditor()),
            if (state.activeEditorTab?.saving == true)
              const LinearProgressIndicator(minHeight: 2),
            if (_terminalVisible(state)) const _EditorTerminal(),
          ],
        ),
        if (showPanels)
          Positioned.fill(
            child: GestureDetector(
              onTap: () {
                state.setEditorFileTreeOpen(false);
                state.setAgentPanelOpen(false);
              },
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
            icon: state.editorFileTreeOpen ? Icons.close : Icons.folder_outlined,
            tooltip: state.editorFileTreeOpen
                ? l10n(context).close
                : l10n(context).files,
            onPressed: () => state.setEditorFileTreeOpen(
              !state.editorFileTreeOpen,
            ),
          ),
        ),
        Positioned(
          top: 48,
          right: 8,
          child: _FloatingToggle(
            icon: state.agentPanelOpen ? Icons.close : Icons.chat_outlined,
            tooltip: state.agentPanelOpen
                ? l10n(context).close
                : l10n(context).chat,
            onPressed: () => state.setAgentPanelOpen(!state.agentPanelOpen),
          ),
        ),
        if (state.editorFileTreeOpen)
          AnimatedPositioned(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            left: 0,
            top: 0,
            bottom: 0,
            width: state.editorTreeWidth.clamp(0, maxWidth * 0.85),
            child: Material(
              elevation: 4,
              color: theme.colorScheme.surface,
              child: const FilesPanel(),
            ),
          ),
        if (state.agentPanelOpen)
          AnimatedPositioned(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            right: 0,
            top: 0,
            bottom: 0,
            width: state.editorAgentPanelWidth.clamp(0, maxWidth * 0.9),
            child: Material(
              elevation: 4,
              color: theme.colorScheme.surface,
              child: const AgentPanel(),
            ),
          ),
      ],
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
