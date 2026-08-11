import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

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

    return ColoredBox(
      color: theme.colorScheme.surfaceContainerLow,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text('Files', style: theme.textTheme.titleMedium),
                ),
                IconButton(
                  tooltip: 'New folder',
                  icon: const Icon(Icons.create_new_folder_outlined),
                  onPressed: () => _promptMkdir(context, state),
                ),
                IconButton(
                  tooltip: 'Close',
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
                  child: Text('root',
                      style: TextStyle(color: theme.colorScheme.primary)),
                ),
                for (final (i, p) in path.indexed) ...[
                  Text(' / '),
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
                        child: Text('Empty folder',
                            style: theme.textTheme.bodyMedium?.copyWith(
                                color:
                                    theme.colorScheme.onSurfaceVariant)),
                      )
                    : ListView(
                        children: [
                          for (final e in entries)
                            ListTile(
                              leading: Icon(
                                e.isDir
                                    ? Icons.folder_outlined
                                    : _fileIcon(e.name),
                                size: 22,
                              ),
                              title: Text(e.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (!e.isDir)
                                    Text(_formatSize(e.size),
                                        style: theme.textTheme.labelSmall),
                                  IconButton(
                                    tooltip: 'Delete',
                                    icon: const Icon(Icons.delete_outline,
                                        size: 18),
                                    onPressed: () async {
                                      if (await _confirm(
                                          context, 'Delete ${e.name}?')) {
                                        state.deleteFile(e.name);
                                      }
                                    },
                                  ),
                                ],
                              ),
                              onTap: e.isDir
                                  ? () => state.navigateFilesInto(e.name)
                                  : null,
                            ),
                        ],
                      ),
          ),
        ],
      ),
    );
  }

  IconData _fileIcon(String name) {
    final ext = name.split('.').last.toLowerCase();
    if (['png', 'jpg', 'jpeg', 'gif', 'webp', 'svg'].contains(ext)) {
      return Icons.image_outlined;
    }
    if (['md', 'txt', 'log'].contains(ext)) return Icons.description_outlined;
    if (['rs', 'js', 'ts', 'py', 'go', 'java', 'c', 'cpp', 'rb'].contains(ext)) {
      return Icons.code;
    }
    if (['json', 'yaml', 'yml', 'toml'].contains(ext)) {
      return Icons.settings_outlined;
    }
    return Icons.insert_drive_file_outlined;
  }

  String _formatSize(int n) {
    if (n < 1024) return '$n B';
    if (n < 1048576) return '${(n / 1024).toStringAsFixed(1)} KB';
    return '${(n / 1048576).toStringAsFixed(1)} MB';
  }

  Future<void> _promptMkdir(BuildContext context, AppState state) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New folder'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Folder name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop(controller.text.trim());
            },
            child: const Text('Create'),
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
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    return result ?? false;
  }
}
