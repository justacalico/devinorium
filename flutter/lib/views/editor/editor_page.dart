import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/l10n.dart';
import '../../state/app_state.dart';
import '../files_panel.dart';
import 'agent_panel.dart';
import 'editor_tab_bar.dart';
import 'file_editor.dart';

const _wideThreshold = 960.0;
const _panelWidth = 320.0;

class EditorPage extends StatefulWidget {
  const EditorPage({super.key});

  @override
  State<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<EditorPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final state = context.read<AppState>();
      if (state.filesTreeRoot.children.isEmpty) {
        state.reloadFiles();
      }
    });
  }

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
          const SizedBox(width: _panelWidth, child: FilesPanel()),
          const VerticalDivider(width: 1),
        ],
        Expanded(
          child: Column(
            children: [
              const EditorTabBar(),
              const Expanded(child: FileEditor()),
              if (state.activeEditorTab?.saving == true)
                const LinearProgressIndicator(minHeight: 2),
            ],
          ),
        ),
        if (state.agentPanelOpen) ...[
          const VerticalDivider(width: 1),
          const SizedBox(width: _panelWidth, child: AgentPanel()),
        ],
      ],
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

    return Stack(
      children: [
        Column(
          children: [
            const EditorTabBar(),
            const Expanded(child: FileEditor()),
            if (state.activeEditorTab?.saving == true)
              const LinearProgressIndicator(minHeight: 2),
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
            icon: state.editorFileTreeOpen
                ? Icons.folder_open
                : Icons.folder_outlined,
            tooltip: l10n(context).files,
            onPressed: () => state.setEditorFileTreeOpen(
              !state.editorFileTreeOpen,
            ),
          ),
        ),
        Positioned(
          top: 48,
          right: 8,
          child: _FloatingToggle(
            icon: state.agentPanelOpen ? Icons.chat : Icons.chat_outlined,
            tooltip: l10n(context).chat,
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
            width: _panelWidth.clamp(0, MediaQuery.of(context).size.width * 0.85),
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
            width: _panelWidth.clamp(0, MediaQuery.of(context).size.width * 0.9),
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
