import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/l10n.dart';
import '../services/editor_launcher.dart';

const _preferredEditorKey = 'devinorium_preferred_editor';

/// Shared launcher so editor detection runs once per process.
final EditorLauncher sharedEditorLauncher = EditorLauncherService();

/// "Open in" split button for the thread header, ported from t3code's
/// OpenInPicker: the main button opens the thread's working directory in the
/// preferred editor, the chevron lists every detected editor plus the OS
/// file manager. Choosing an entry also makes it the preferred editor.
///
/// Only usable on desktop builds against the bundled server — callers gate
/// on the server profile and [EditorLauncher.isSupported] hides it on
/// web/mobile.
class OpenInButton extends StatefulWidget {
  const OpenInButton({super.key, required this.path, this.launcher});

  /// The directory to open (thread worktree or project path).
  final String path;

  /// Injectable for tests; defaults to the shared platform launcher.
  final EditorLauncher? launcher;

  @override
  State<OpenInButton> createState() => _OpenInButtonState();
}

class _OpenInButtonState extends State<OpenInButton> {
  late final EditorLauncher _launcher = widget.launcher ?? sharedEditorLauncher;
  late final Future<List<EditorApp>> _editorsFuture = _load();
  String? _preferredId;

  Future<List<EditorApp>> _load() async {
    final editors = await _launcher.detectEditors();
    try {
      final prefs = await SharedPreferences.getInstance();
      _preferredId = prefs.getString(_preferredEditorKey);
    } catch (_) {}
    return editors;
  }

  EditorApp _primary(List<EditorApp> editors) {
    for (final e in editors) {
      if (e.id == _preferredId) return e;
    }
    for (final e in editors) {
      if (e.id == 'vscode') return e;
    }
    return editors.first;
  }

  String _labelFor(EditorApp editor) => editor.isFileManager
      ? fileManagerLabel(defaultTargetPlatform)
      : editor.label;

  Future<void> _open(EditorApp editor) async {
    final ok = await _launcher.open(widget.path, editor.id);
    if (ok) {
      _preferredId = editor.id;
      unawaited(_persistPreferred(editor.id));
      if (mounted) setState(() {});
      return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n(context).openInFailed(_labelFor(editor)))),
    );
  }

  Future<void> _persistPreferred(String id) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_preferredEditorKey, id);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    if (!_launcher.isSupported) return const SizedBox.shrink();
    final l = l10n(context);
    return FutureBuilder<List<EditorApp>>(
      future: _editorsFuture,
      builder: (context, snapshot) {
        final editors = snapshot.data ?? const <EditorApp>[];
        if (editors.isEmpty) return const SizedBox.shrink();
        final primary = _primary(editors);
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              key: const Key('open_in_primary'),
              tooltip: l.openInEditor(_labelFor(primary)),
              icon: const Icon(Icons.open_in_new),
              onPressed: () => unawaited(_open(primary)),
            ),
            PopupMenuButton<String>(
              key: const Key('open_in_menu'),
              tooltip: l.openInMenu,
              icon: const Icon(Icons.arrow_drop_down),
              onSelected: (id) {
                final editor = editors.firstWhere(
                  (e) => e.id == id,
                  orElse: () => primary,
                );
                unawaited(_open(editor));
              },
              itemBuilder: (context) => [
                for (final editor in editors)
                  PopupMenuItem<String>(
                    value: editor.id,
                    child: Row(
                      children: [
                        Icon(
                          editor.isFileManager ? Icons.folder_open : Icons.code,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Expanded(child: Text(_labelFor(editor))),
                        if (editor.id == primary.id)
                          const Icon(Icons.check, size: 16),
                      ],
                    ),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}
