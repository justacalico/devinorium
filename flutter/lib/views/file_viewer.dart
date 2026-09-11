import 'dart:convert';

import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import 'diff_view.dart';
import 'syntax_highlighter.dart';

/// Number of content lines shown before the user has to opt in to the full
/// file. Keeps large files from freezing the initial render.
const _maxInitialContentLines = 2000;

/// Opens a full-screen route that loads and displays a single file.
///
/// The viewer shows the file content with syntax highlighting and, when the
/// file has git changes, a diff view. It is implemented as a standalone
/// reusable widget so it can be reused by a future editor/IDE mode.
class FileViewerPage extends StatefulWidget {
  final String path;
  final int? projectId;
  final String? threadId;
  final String? gitStatus;

  const FileViewerPage({
    super.key,
    required this.path,
    this.projectId,
    this.threadId,
    this.gitStatus,
  });

  @override
  State<FileViewerPage> createState() => _FileViewerPageState();
}

class _FileViewerPageState extends State<FileViewerPage> {
  FileContent? _content;
  String? _error;
  bool _loading = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loading) {
      _load();
    }
  }

  Future<void> _load() async {
    final api = context.read<AppState>().api;
    final includeDiff = widget.gitStatus != null &&
        widget.gitStatus != 'ignored' &&
        widget.gitStatus != 'renamed' &&
        widget.gitStatus != 'copied';
    try {
      final content = await api.readFile(
        path: widget.path,
        projectId: widget.projectId,
        threadId: widget.threadId,
        includeDiff: includeDiff,
      );
      if (mounted) {
        setState(() {
          _content = content;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = l10n(context);

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text(_basename(widget.path)),
        actions: [
          if (_content?.text?.isNotEmpty ?? false)
            IconButton(
              icon: const Icon(Icons.copy_outlined),
              tooltip: l.copy,
              onPressed: () => Clipboard.setData(
                ClipboardData(text: _content!.text!),
              ),
            ),
        ],
      ),
      body: _buildBody(theme, l),
    );
  }

  Widget _buildBody(ThemeData theme, AppLocalizations l) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '${l.fileViewerLoadError}: $_error',
            style: TextStyle(color: theme.colorScheme.error),
          ),
        ),
      );
    }
    final content = _content!;
    return FileViewer(
      content: content,
      initialShowDiff: _defaultToDiff(widget.gitStatus),
    );
  }

  static bool _defaultToDiff(String? status) {
    return status == 'modified' ||
        status == 'conflict' ||
        status == 'added' ||
        status == 'untracked';
  }

  static String _basename(String path) {
    if (path.isEmpty) return path;
    if (path.contains('\\')) {
      return p.Context(style: p.Style.windows).basename(path);
    }
    return p.basename(path);
  }
}

/// Displays a loaded [FileContent] and lets the user switch between the
/// content and its git diff. Kept separate from [FileViewerPage] so it can
/// be embedded in other layouts.
class FileViewer extends StatefulWidget {
  final FileContent content;
  final bool initialShowDiff;

  const FileViewer({
    super.key,
    required this.content,
    this.initialShowDiff = false,
  });

  @override
  State<FileViewer> createState() => _FileViewerState();
}

class _FileViewerState extends State<FileViewer> {
  late bool _showDiff = widget.initialShowDiff;

  @override
  Widget build(BuildContext context) {
    final l = l10n(context);
    final hasDiff = widget.content.diff != null;

    return Column(
      children: [
        if (hasDiff) ...[
          Padding(
            padding: const EdgeInsets.all(12),
            child: SegmentedButton<bool>(
              selected: {_showDiff},
              onSelectionChanged: (s) {
                if (s.isNotEmpty) {
                  setState(() => _showDiff = s.first);
                }
              },
              segments: [
                ButtonSegment<bool>(
                  value: false,
                  label: Text(l.fileViewerContent),
                ),
                ButtonSegment<bool>(
                  value: true,
                  label: Text(l.fileViewerDiff),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
        ],
        Expanded(
          child: _showDiff && hasDiff
              ? _DiffTab(diff: widget.content.diff!)
              : _ContentTab(content: widget.content),
        ),
      ],
    );
  }
}

class _ContentTab extends StatefulWidget {
  final FileContent content;

  const _ContentTab({required this.content});

  @override
  State<_ContentTab> createState() => _ContentTabState();
}

class _ContentTabState extends State<_ContentTab> {
  bool _showAll = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = l10n(context);

    if (widget.content.text == null) {
      return Center(
        child: Text(
          '${l.fileViewerBinaryFile} • ${widget.content.mime} • ${_formatSize(widget.content.size, l)}',
          style: theme.textTheme.bodyMedium,
        ),
      );
    }

    if (widget.content.text!.isEmpty) {
      return Center(child: Text(l.readFileNoContent));
    }

    final lines = const LineSplitter().convert(widget.content.text!);
    final truncated = !_showAll && lines.length > _maxInitialContentLines;
    final displayText = truncated
        ? lines.sublist(0, _maxInitialContentLines).join('\n')
        : widget.content.text!;
    final hidden = lines.length - _maxInitialContentLines;

    final language = _languageFromPath(widget.content.path);
    final highlighter = SyntaxHighlighter(theme);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText.rich(
            highlighter.highlight(displayText, language),
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 13,
              height: 1.4,
            ),
          ),
          if (truncated) ...[
            const SizedBox(height: 12),
            Text(
              l.contentViewMoreLines(hidden),
              style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontStyle: FontStyle.italic,
                  ),
            ),
            TextButton(
              onPressed: () => setState(() => _showAll = true),
              child: Text(l.contentViewShowAll),
            ),
          ],
        ],
      ),
    );
  }
}

class _DiffTab extends StatelessWidget {
  final FileDiff diff;

  const _DiffTab({required this.diff});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      child: DiffView(diff: diff),
    );
  }
}

String _languageFromPath(String path) {
  final lower = path.toLowerCase();
  final ext = lower.contains('.') ? lower.split('.').last : '';

  return switch (ext) {
    'dart' => 'dart',
    'rs' => 'rust',
    'py' => 'python',
    'js' || 'jsx' || 'mjs' => 'javascript',
    'ts' || 'tsx' => 'typescript',
    'json' => 'json',
    'yaml' || 'yml' => 'yaml',
    'html' || 'htm' || 'xml' => 'html',
    'css' || 'scss' || 'sass' || 'less' => 'css',
    'sh' || 'bash' || 'zsh' || 'fish' => 'bash',
    'sql' => 'sql',
    'md' || 'markdown' => 'markdown',
    'c' || 'h' || 'cpp' || 'cc' || 'hpp' => 'c',
    'go' => 'go',
    'java' || 'kt' || 'kts' => 'java',
    'php' => 'php',
    'rb' => 'ruby',
    'swift' => 'swift',
    _ => 'text',
  };
}

String _formatSize(int n, AppLocalizations l) {
  if (n < 1024) return l.sizeBytes('$n');
  if (n < 1048576) {
    return l.sizeKilobytes((n / 1024).toStringAsFixed(1));
  }
  return l.sizeMegabytes((n / 1048576).toStringAsFixed(1));
}
