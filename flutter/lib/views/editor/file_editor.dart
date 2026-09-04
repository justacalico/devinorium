import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../l10n/l10n.dart';
import '../../state/app_state.dart';
import '../file_viewer.dart';

class FileEditor extends StatefulWidget {
  const FileEditor({super.key});

  @override
  State<FileEditor> createState() => _FileEditorState();
}

class _FileEditorState extends State<FileEditor> {
  final _controllers = <String, TextEditingController>{};
  final _focusNode = FocusNode();

  @override
  void dispose() {
    _focusNode.dispose();
    for (final c in _controllers.values) {
      c.dispose();
    }
    _controllers.clear();
    super.dispose();
  }

  TextEditingController _controllerFor(String path, String text) {
    var c = _controllers[path];
    if (c == null) {
      c = TextEditingController(text: text);
      _controllers[path] = c;
      return c;
    }

    if (c.text != text) {
      final sel = c.selection;
      c.text = text;
      final len = c.text.length;
      final base = sel.baseOffset.clamp(0, len);
      final extent = sel.extentOffset.clamp(0, len);
      c.selection = sel.copyWith(
        baseOffset: base,
        extentOffset: extent,
      );
    }
    return c;
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final tab = state.activeEditorTab;

    if (tab == null) {
      return _EmptyBody(text: l10n(context).editorSelectFile);
    }

    if (tab.loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (tab.error != null) {
      return _ErrorBody(
        error: tab.error!,
        tab: tab,
        hasContent: tab.content != null,
      );
    }

    if (tab.content == null) {
      return const SizedBox.shrink();
    }

    if (tab.showDiff) {
      return FileViewer(content: tab.content!, initialShowDiff: true);
    }

    if (tab.content!.text == null) {
      return _EmptyBody(text: l10n(context).binaryFileNotEditable(tab.name));
    }

    final controller = _controllerFor(tab.path, tab.text);
    return Focus(
      focusNode: _focusNode,
      onKeyEvent: _onKeyEvent,
      child: TextField(
        key: ValueKey('editor-${tab.path}'),
        controller: controller,
        maxLines: null,
        expands: true,
        keyboardType: TextInputType.multiline,
        textAlignVertical: TextAlignVertical.top,
        style: TextStyle(
          fontFamily: 'monospace',
          fontFamilyFallback: const ['Consolas', 'Monaco', 'Courier New'],
          fontSize: 14,
          color: Theme.of(context).colorScheme.onSurface,
        ),
        decoration: const InputDecoration(
          contentPadding: EdgeInsets.all(12),
          border: InputBorder.none,
        ),
        onChanged: (value) => state.setEditorTabText(tab.path, value),
      ),
    );
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final isControl = HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    if (isControl && event.logicalKey == LogicalKeyboardKey.keyS) {
      final state = context.read<AppState>();
      final tab = state.activeEditorTab;
      if (tab != null) {
        unawaited(state.saveEditorTab(tab.path));
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }
}

class _EmptyBody extends StatelessWidget {
  final String text;

  const _EmptyBody({required this.text});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        text,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _ErrorBody extends StatelessWidget {
  final String error;
  final EditorTab tab;
  final bool hasContent;

  const _ErrorBody({
    required this.error,
    required this.tab,
    required this.hasContent,
  });

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final theme = Theme.of(context);

    return Column(
      children: [
        Material(
          color: theme.colorScheme.errorContainer,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Icon(Icons.error_outline, color: theme.colorScheme.error, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    error,
                    style: TextStyle(color: theme.colorScheme.onErrorContainer),
                  ),
                ),
                TextButton(
                  onPressed: () => state.reloadEditorTab(tab.path),
                  child: Text(l10n(context).retry),
                ),
                if (hasContent)
                  TextButton(
                    onPressed: () => state.setEditorTabText(tab.path, tab.content!.text ?? ''),
                    child: Text(l10n(context).editorDiscard),
                  ),
              ],
            ),
          ),
        ),
        if (hasContent)
          Expanded(
            child: FileViewer(content: tab.content!, initialShowDiff: false),
          )
        else
          const Expanded(child: SizedBox.shrink()),
      ],
    );
  }
}
