import 'package:flutter/material.dart';

import '../api/api_service.dart';
import '../l10n/l10n.dart';
import 'folder_picker.dart';

/// Shows a folder picker dialog and returns the selected path, or `null` if
/// the user cancelled.
///
/// The picker behaves like the new-project folder browser: it starts at the
/// user's home directory, supports `~` and absolute paths, and returns a
/// string such as `~`, `~/clones` or `/srv/clones`.
Future<String?> showFolderPickerDialog(
  BuildContext context, {
  required ApiService api,
  String? initialPath,
  String? title,
}) {
  return showDialog<String>(
    context: context,
    builder: (context) =>
        _FolderPickerDialog(api: api, initialPath: initialPath, title: title),
  );
}

class _FolderPickerDialog extends StatelessWidget {
  final ApiService api;
  final String? initialPath;
  final String? title;

  const _FolderPickerDialog({required this.api, this.initialPath, this.title});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = l10n(context);

    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 560),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title ?? l.cloneRoot, style: theme.textTheme.headlineSmall),
              const SizedBox(height: 16),
              Expanded(
                child: FolderPicker(
                  api: api,
                  initialPath: initialPath,
                  homePrefix: '~',
                  // The dialog only needs the selected path; isHomeRoot is
                  // unused because the home root path (`~`) is a valid value.
                  onSelect: (path, _) => Navigator.of(context).pop(path),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(l.cancel),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
