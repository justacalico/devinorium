import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import '../state/app_state.dart';

class FilesPanel extends StatelessWidget {
  const FilesPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final entries = state.filesEntries;
    final path = state.filesPath;
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
                  child: Text(l10n(context).files, style: theme.textTheme.titleMedium),
                ),
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
          // Breadcrumb
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                InkWell(
                  onTap: () => state.navigateFilesTo(const []),
                  child: Text(l10n(context).root,
                      style: TextStyle(color: theme.colorScheme.primary)),
                ),
                for (final (i, p) in path.indexed) ...[
                  Text(l10n(context).breadcrumbSeparator),
                  InkWell(
                    onTap: () => state.navigateFilesTo(path.sublist(0, i + 1)),
                    child: Text(p,
                        style: TextStyle(color: theme.colorScheme.primary)),
                  ),
                ],
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: error.isNotEmpty
                ? Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(error,
                        style: TextStyle(color: theme.colorScheme.error)),
                  )
                : entries.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(l10n(context).emptyFolder,
                            style: theme.textTheme.bodyMedium?.copyWith(
                                color:
                                    theme.colorScheme.onSurfaceVariant)),
                      )
                    : ListView.builder(
                        itemCount: entries.length +
                            (state.hasMoreFiles || state.isLoadingMoreFiles
                                ? 1
                                : 0),
                        itemBuilder: (context, index) {
                          if (index == entries.length) {
                            return Padding(
                              padding:
                                  const EdgeInsets.fromLTRB(12, 4, 12, 12),
                              child: state.isLoadingMoreFiles
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2),
                                    )
                                  : TextButton(
                                      onPressed: () => state.loadMoreFiles(),
                                      child: const Text('Load more'),
                                    ),
                            );
                          }
                          final e = entries[index];
                          return ListTile(
                            leading: Icon(
                              e.isDir
                                  ? Icons.folder_outlined
                                  : _fileIcon(e.name),
                              size: 22,
                              color: e.isDir
                                  ? theme.colorScheme.primary
                                  : _fileIconColor(e.name, theme),
                            ),
                            title: Text(e.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (!e.isDir)
                                  Text(_formatSize(e.size, l10n(context)),
                                      style: theme.textTheme.labelSmall),
                                IconButton(
                                  tooltip: l10n(context).delete,
                                  icon: const Icon(Icons.delete_outline,
                                      color: Colors.red, size: 18),
                                  onPressed: () async {
                                    if (await _confirm(
                                        context, l10n(context).deleteName(e.name))) {
                                      state.deleteFile(e.name);
                                    }
                                  },
                                ),
                              ],
                            ),
                            onTap: e.isDir
                                ? () => state.navigateFilesInto(e.name)
                                : null,
                          );
                        },
                      ),
          ),
        ],
      ),
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
    if (['png', 'jpg', 'jpeg', 'gif', 'webp', 'svg', 'bmp', 'ico'].contains(ext)) {
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
    if (['xls', 'xlsx', 'csv'].contains(ext)) return Icons.table_chart_outlined;
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
    if (['json', 'yaml', 'yml', 'toml', 'ini', 'cfg', 'conf', 'env'].contains(ext)) {
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

    if (['png', 'jpg', 'jpeg', 'gif', 'webp', 'svg', 'bmp', 'ico'].contains(ext)) {
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
    if (['css', 'scss', 'sass', 'less'].contains(ext)) return Colors.blue.shade400;
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
    if (['json', 'yaml', 'yml', 'toml', 'ini', 'cfg', 'conf', 'env'].contains(ext)) {
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
