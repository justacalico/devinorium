import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import 'file_viewer.dart';

class FilesPanel extends StatefulWidget {
  const FilesPanel({super.key});

  @override
  State<FilesPanel> createState() => _FilesPanelState();
}

class _FilesPanelState extends State<FilesPanel> {
  @override
  void initState() {
    super.initState();
    _loadIfNeeded(context.read<AppState>());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _loadIfNeeded(context.read<AppState>());
  }

  void _loadIfNeeded(AppState state) {
    if (state.filesProjectId == state.activeProjectId) return;
    unawaited(state.reloadFiles());
  }

  @override
  Widget build(BuildContext context) {
    context.watch<AppState>();
    return const _FilesPanelBody();
  }
}

class _FilesPanelBody extends StatelessWidget {
  const _FilesPanelBody();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final rows = state.filesTreeRows;
    final error = state.filesError;

    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    l10n(context).files,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                if (state.activeProjectId != null)
                  IconButton(
                    tooltip: l10n(context).newFolder,
                    icon: const Icon(Icons.create_new_folder_outlined),
                    onPressed: () => _promptMkdir(context, state),
                  ),
                IconButton(
                  tooltip: l10n(context).close,
                  icon: const Icon(Icons.close),
                  onPressed: state.closeFilesPanel,
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          if (error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                error,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
          Expanded(
            child: state.activeProjectId == null
                ? _EmptyPlaceholder(
                    text: l10n(context).selectProjectFirst,
                  )
                : rows.isEmpty
                    ? error.isNotEmpty
                        ? const SizedBox.shrink()
                        : _EmptyPlaceholder(
                            text: l10n(context).emptyFolder,
                          )
                    : ListView.builder(
                        itemCount: rows.length,
                        itemBuilder: (context, index) =>
                            _buildRow(context, state, rows[index], theme),
                      ),
          ),
        ],
      ),
    );
  }

  void _openFile(BuildContext context, AppState state, FileTreeNode node) {
    if (state.appMode == AppMode.editor) {
      state.openEditorFile(node.fullPathString);
      final scaffold = Scaffold.maybeOf(context);
      if (scaffold?.isDrawerOpen ?? false) {
        scaffold!.closeDrawer();
      }
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => FileViewerPage(
          path: node.fullPathString,
          projectId: state.activeProjectId,
          gitStatus: node.entry.gitStatus,
        ),
      ),
    );
  }

  Widget _buildRow(
    BuildContext context,
    AppState state,
    FileTreeRow row,
    ThemeData theme,
  ) {
    final leftPadding = 12.0 + row.indent * 20.0;

    if (row.kind == FileTreeRowKind.loading) {
      return Padding(
        padding: EdgeInsets.fromLTRB(leftPadding, 12, 12, 12),
        child: const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    if (row.kind == FileTreeRowKind.error) {
      return Padding(
        padding: EdgeInsets.fromLTRB(leftPadding, 4, 12, 4),
        child: Text(
          row.node.error,
          style: TextStyle(color: theme.colorScheme.error, fontSize: 12),
        ),
      );
    }

    if (row.kind == FileTreeRowKind.empty) {
      return Padding(
        padding: EdgeInsets.fromLTRB(leftPadding, 4, 12, 4),
        child: Text(
          l10n(context).emptyFolder,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    if (row.kind == FileTreeRowKind.loadMore) {
      return Padding(
        padding: EdgeInsets.fromLTRB(leftPadding, 4, 12, 12),
        child: row.node.isLoadingMore
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : TextButton(
                onPressed: () => state.loadMoreFiles(node: row.node),
                child: Text(l10n(context).loadMore),
              ),
      );
    }

    final node = row.node;
    final isDir = node.entry.isDir;
    final icon = isDir
        ? (node.isExpanded ? Icons.folder_open_outlined : Icons.folder_outlined)
        : _fileIcon(node.entry.name);
    final color = isDir
        ? theme.colorScheme.primary
        : _fileIconColor(node.entry.name, theme);
    final titleColor = node.entry.gitStatus != null
        ? _gitStatusColor(node.entry.gitStatus!, theme)
        : null;

    return ListTile(
      contentPadding: EdgeInsets.only(left: leftPadding, right: 12),
      leading: Icon(icon, size: 22, color: color),
      title: Text(
        node.entry.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: titleColor != null ? TextStyle(color: titleColor) : null,
      ),
      trailing: isDir
          ? _deleteButton(context, state, node)
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _formatSize(node.entry.size, l10n(context)),
                  style: theme.textTheme.labelSmall,
                ),
                _deleteButton(context, state, node),
              ],
            ),
      onTap: isDir
          ? () => state.toggleFilesFolder(node)
          : () => _openFile(context, state, node),
    );
  }

  Widget _deleteButton(
    BuildContext context,
    AppState state,
    FileTreeNode node,
  ) {
    return IconButton(
      tooltip: l10n(context).delete,
      icon: const Icon(Icons.delete_outline, color: Colors.red, size: 18),
      onPressed: () async {
        if (await _confirm(
          context,
          l10n(context).deleteName(node.entry.name),
        )) {
          state.deleteFile(node.fullPathString);
        }
      },
    );
  }

  IconData _fileIcon(String name) {
    final lower = name.toLowerCase();
    final ext = lower.contains('.') ? lower.split('.').last : '';

    // Special filenames.
    if (lower == 'pubspec.yaml' || lower == 'pubspec.lock') {
      return Icons.inventory_2_outlined;
    }
    if (lower == '.gitignore' || lower == '.gitattributes') {
      return Icons.merge_type_outlined;
    }
    if (lower == 'dockerfile' || lower.startsWith('dockerfile.')) {
      return Icons.dns_outlined;
    }
    if (lower == 'makefile' || lower == 'cmakelists.txt') {
      return Icons.build_outlined;
    }
    if (lower == 'license' || lower.startsWith('license.')) {
      return Icons.gavel_outlined;
    }
    if (lower == 'readme.md' || lower == 'readme') {
      return Icons.menu_book_outlined;
    }

    // Image files.
    if ([
      'png',
      'jpg',
      'jpeg',
      'gif',
      'webp',
      'svg',
      'bmp',
      'ico',
    ].contains(ext)) {
      return Icons.image_outlined;
    }

    // Video files.
    if (['mp4', 'avi', 'mov', 'mkv', 'webm'].contains(ext)) {
      return Icons.movie_outlined;
    }

    // Audio files.
    if (['mp3', 'wav', 'ogg', 'flac', 'm4a'].contains(ext)) {
      return Icons.audio_file_outlined;
    }

    // Archive files.
    if (['zip', 'tar', 'gz', 'bz2', '7z', 'rar', 'xz'].contains(ext)) {
      return Icons.folder_zip_outlined;
    }

    // Web files.
    if (['html', 'htm'].contains(ext)) return Icons.html_outlined;
    if (['css', 'scss', 'sass', 'less'].contains(ext)) {
      return Icons.format_paint_outlined;
    }

    // Markup / docs.
    if (['md', 'rst', 'txt', 'log'].contains(ext)) {
      return Icons.description_outlined;
    }
    if (['pdf'].contains(ext)) return Icons.picture_as_pdf_outlined;
    if (['doc', 'docx'].contains(ext)) return Icons.article_outlined;
    if (['xls', 'xlsx', 'csv'].contains(ext)) {
      return Icons.table_chart_outlined;
    }
    if (['ppt', 'pptx'].contains(ext)) return Icons.slideshow_outlined;

    // Programming languages.
    if (ext == 'dart') return Icons.code;
    if (['rs', 'c', 'cpp', 'cc', 'h', 'hpp'].contains(ext)) {
      return Icons.memory;
    }
    if (['js', 'jsx', 'mjs'].contains(ext)) return Icons.javascript;
    if (['ts', 'tsx'].contains(ext)) return Icons.data_object;
    if (['py'].contains(ext)) return Icons.terminal;
    if (['go'].contains(ext)) return Icons.speed;
    if (['java', 'kt', 'kts'].contains(ext)) return Icons.coffee;
    if (['rb'].contains(ext)) return Icons.diamond_outlined;
    if (['swift'].contains(ext)) return Icons.flutter_dash;
    if (['sh', 'bash', 'zsh', 'fish'].contains(ext)) {
      return Icons.terminal;
    }
    if (['lua'].contains(ext)) return Icons.code;
    if (['php'].contains(ext)) return Icons.code;
    if (['vue'].contains(ext)) return Icons.dynamic_form_outlined;
    if (['svelte'].contains(ext)) return Icons.layers_outlined;

    // Config / data.
    if ([
      'json',
      'yaml',
      'yml',
      'toml',
      'ini',
      'cfg',
      'conf',
      'env',
    ].contains(ext)) {
      return Icons.settings_outlined;
    }
    if (['xml'].contains(ext)) return Icons.code;
    if (['lock'].contains(ext)) return Icons.lock_outline;

    // Database.
    if (['db', 'sqlite', 'sql'].contains(ext)) return Icons.storage_outlined;

    // Executables / binaries.
    if (['exe', 'bin', 'dll', 'so', 'dylib'].contains(ext)) {
      return Icons.apps_outlined;
    }

    // Font files.
    if (['ttf', 'otf', 'woff', 'woff2'].contains(ext)) {
      return Icons.text_fields_outlined;
    }

    return Icons.insert_drive_file_outlined;
  }

  Color _fileIconColor(String name, ThemeData theme) {
    final lower = name.toLowerCase();
    final ext = lower.contains('.') ? lower.split('.').last : '';

    if (lower == 'pubspec.yaml' || lower == 'pubspec.lock') {
      return Colors.blue;
    }
    if (lower == '.gitignore' || lower == '.gitattributes') {
      return Colors.orange;
    }
    if (lower == 'dockerfile' || lower.startsWith('dockerfile.')) {
      return Colors.blue.shade700;
    }
    if (lower == 'readme.md' || lower == 'readme') {
      return Colors.teal;
    }
    if (lower == 'license' || lower.startsWith('license.')) {
      return Colors.purple;
    }

    if ([
      'png',
      'jpg',
      'jpeg',
      'gif',
      'webp',
      'svg',
      'bmp',
      'ico',
    ].contains(ext)) {
      return Colors.pink;
    }
    if (['mp4', 'avi', 'mov', 'mkv', 'webm'].contains(ext)) {
      return Colors.red;
    }
    if (['mp3', 'wav', 'ogg', 'flac', 'm4a'].contains(ext)) {
      return Colors.orange;
    }
    if (['zip', 'tar', 'gz', 'bz2', '7z', 'rar', 'xz'].contains(ext)) {
      return Colors.brown;
    }
    if (['html', 'htm'].contains(ext)) return Colors.orange;
    if (['css', 'scss', 'sass', 'less'].contains(ext)) {
      return Colors.blue.shade400;
    }
    if (['md', 'rst', 'txt', 'log'].contains(ext)) {
      return theme.colorScheme.onSurfaceVariant;
    }
    if (['pdf'].contains(ext)) return Colors.red;
    if (['doc', 'docx'].contains(ext)) return Colors.blue;
    if (['xls', 'xlsx', 'csv'].contains(ext)) return Colors.green;
    if (['ppt', 'pptx'].contains(ext)) return Colors.deepOrange;

    if (ext == 'dart') return Colors.cyan;
    if (['rs', 'c', 'cpp', 'cc', 'h', 'hpp'].contains(ext)) {
      return Colors.deepOrange;
    }
    if (['js', 'jsx', 'mjs'].contains(ext)) return Colors.amber;
    if (['ts', 'tsx'].contains(ext)) return Colors.blue;
    if (['py'].contains(ext)) return Colors.blue.shade700;
    if (['go'].contains(ext)) return Colors.cyan.shade700;
    if (['java', 'kt', 'kts'].contains(ext)) return Colors.orange;
    if (['rb'].contains(ext)) return Colors.red;
    if (['swift'].contains(ext)) return Colors.orange;
    if (['sh', 'bash', 'zsh', 'fish'].contains(ext)) {
      return Colors.green.shade700;
    }
    if ([
      'json',
      'yaml',
      'yml',
      'toml',
      'ini',
      'cfg',
      'conf',
      'env',
    ].contains(ext)) {
      return Colors.grey;
    }
    if (['lock'].contains(ext)) return Colors.amber;
    if (['db', 'sqlite', 'sql'].contains(ext)) return Colors.indigo;
    if (['exe', 'bin', 'dll', 'so', 'dylib'].contains(ext)) {
      return Colors.grey.shade600;
    }
    if (['ttf', 'otf', 'woff', 'woff2'].contains(ext)) {
      return Colors.purple.shade300;
    }

    return theme.colorScheme.onSurfaceVariant;
  }

  String _formatSize(int n, AppLocalizations l) {
    if (n < 1024) return l.sizeBytes('$n');
    if (n < 1048576) {
      return l.sizeKilobytes((n / 1024).toStringAsFixed(1));
    }
    return l.sizeMegabytes((n / 1048576).toStringAsFixed(1));
  }

  Color _gitStatusColor(String status, ThemeData theme) {
    return switch (status) {
      'modified' => Colors.orange,
      'added' => Colors.green,
      'deleted' => Colors.red,
      'renamed' => Colors.purple,
      'copied' => Colors.pink,
      'untracked' => Colors.blue,
      'conflict' => Colors.redAccent,
      'ignored' => theme.colorScheme.onSurfaceVariant,
      'descendant' => Colors.orange,
      _ => theme.colorScheme.onSurfaceVariant,
    };
  }

  Future<void> _promptMkdir(BuildContext context, AppState state) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n(context).newFolder),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: l10n(context).folderNameHint),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(l10n(context).cancel),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop(controller.text.trim());
            },
            child: Text(l10n(context).create),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name != null && name.isNotEmpty) {
      state.mkdir(name);
    }
  }

  Future<bool> _confirm(BuildContext context, String message) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n(context).cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n(context).delete),
          ),
        ],
      ),
    );
    return result ?? false;
  }
}

class _EmptyPlaceholder extends StatelessWidget {
  final String text;

  const _EmptyPlaceholder({required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Text(
        text,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
