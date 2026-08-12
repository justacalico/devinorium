import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/app_state.dart';

class DialogLayer extends StatelessWidget {
  const DialogLayer({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    switch (state.dialog) {
      case DialogKind.none:
        return const SizedBox.shrink();
      case DialogKind.totpSetup:
        return const _TotpSetupDialog();
      case DialogKind.invites:
        return const _InvitesDialog();
      case DialogKind.newProject:
        return const _NewProjectDialog();
      case DialogKind.permissionRequest:
        return const _PermissionRequestDialog();
    }
  }
}

class _TotpSetupDialog extends StatefulWidget {
  const _TotpSetupDialog();

  @override
  State<_TotpSetupDialog> createState() => _TotpSetupDialogState();
}

class _TotpSetupDialogState extends State<_TotpSetupDialog> {
  final _codeController = TextEditingController();

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    return Stack(
      children: [
        ModalBarrier(color: Colors.black.withValues(alpha: 0.5), dismissible: false),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Card(
              margin: const EdgeInsets.all(24),
              elevation: 3,
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('Enable 2FA', style: theme.textTheme.headlineSmall),
                    const SizedBox(height: 12),
                    const Text(
                      'Scan this secret in your authenticator app, then enter the current code.',
                    ),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHigh,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: SelectableText(
                        state.totpSecret,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(fontFamily: 'monospace'),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _codeController,
                      decoration: const InputDecoration(
                        labelText: 'TOTP code',
                        hintText: '000000',
                        border: OutlineInputBorder(),
                      ),
                      keyboardType: TextInputType.number,
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: state.closeDialog,
                          child: const Text('Cancel'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: () {
                            state.verifyTotp(_codeController.text.trim());
                          },
                          child: const Text('Verify'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _InvitesDialog extends StatelessWidget {
  const _InvitesDialog();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final invites = state.invites;
    return Stack(
      children: [
        ModalBarrier(color: Colors.black.withValues(alpha: 0.5), dismissible: false),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Card(
              margin: const EdgeInsets.all(24),
              elevation: 3,
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text('Invite tokens',
                              style: theme.textTheme.headlineSmall),
                        ),
                        IconButton.filled(
                          onPressed: state.createInvite,
                          icon: const Icon(Icons.add),
                          tooltip: 'Create invite',
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Share a token so someone can register. Tokens are single-use and expire in 7 days.',
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      height: 240,
                      child: invites.isEmpty
                          ? Center(
                              child: Text('No invites yet.',
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                      color:
                                          theme.colorScheme.onSurfaceVariant)),
                            )
                          : ListView.separated(
                              itemCount: invites.length,
                              separatorBuilder: (_, _) =>
                                  const SizedBox(height: 6),
                              itemBuilder: (_, i) {
                                final inv = invites[i];
                                return Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 8),
                                  decoration: BoxDecoration(
                                    color:
                                        theme.colorScheme.surfaceContainerHigh,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: SelectableText(
                                          inv.token,
                                          style: theme.textTheme.bodySmall
                                              ?.copyWith(
                                                  fontFamily: 'monospace'),
                                        ),
                                      ),
                                      Text(
                                        inv.isUsed ? 'Used' : 'Available',
                                        style: theme.textTheme.labelSmall
                                            ?.copyWith(
                                          color: inv.isUsed
                                              ? theme.colorScheme.error
                                              : theme.colorScheme.tertiary,
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: state.closeDialog,
                          child: const Text('Close'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _NewProjectDialog extends StatefulWidget {
  const _NewProjectDialog();

  @override
  State<_NewProjectDialog> createState() => _NewProjectDialogState();
}

class _NewProjectDialogState extends State<_NewProjectDialog> {
  final _nameController = TextEditingController();
  final _pathController = TextEditingController();
  final _pathSegments = <String>[];
  var _entries = <DirEntry>[];
  var _loading = true;
  var _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _pathController.dispose();
    super.dispose();
  }

  String get _currentPath => _pathSegments.join('/');

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final state = context.read<AppState>();
      final entries = await state.api.listFiles(
        path: _currentPath.isEmpty ? null : _currentPath,
        projectId: null,
      );
      if (!mounted) return;
      setState(() {
        _entries = entries
            .where((e) => e.isDir && !e.name.startsWith('.'))
            .toList();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  void _enter(String name) {
    if (_loading) return;
    _pathSegments.add(name);
    _load();
  }

  void _up() {
    if (_loading || _pathSegments.isEmpty) return;
    _pathSegments.removeLast();
    _load();
  }

  void _goTo(int index) {
    if (_loading) return;
    if (index < 0) {
      _pathSegments.clear();
    } else if (index < _pathSegments.length) {
      _pathSegments.removeRange(index + 1, _pathSegments.length);
    } else {
      return;
    }
    _load();
  }

  void _selectCurrent() {
    _pathController.text = _currentPath;
  }

  void _jumpToTextPath() {
    setState(() => _error = null);
    final text = _pathController.text.trim();
    if (text.isEmpty) {
      _pathSegments.clear();
      _load();
      return;
    }
    if (text.startsWith('/')) {
      setState(() => _error = 'Absolute paths cannot be browsed; type a path relative to the file root');
      return;
    }
    final normalized = text.replaceAll(RegExp(r'/+'), '/');
    if (normalized.contains('..')) {
      setState(() => _error = 'Path traversal is not allowed');
      return;
    }
    final segs = normalized
        .split('/')
        .where((s) => s.isNotEmpty && s != '.')
        .toList();
    _pathSegments
      ..clear()
      ..addAll(segs);
    _load();
  }

  Future<void> _submit() async {
    final name = _nameController.text.trim();
    final path = _pathController.text.trim();
    if (name.isEmpty || path.isEmpty) {
      setState(() => _error = 'Name and path are required');
      return;
    }

    setState(() => _submitting = true);
    try {
      final state = context.read<AppState>();
      await state.createProject(name: name, path: path);
      if (mounted) {
        setState(() => _submitting = false);
        if (state.globalError.isEmpty) {
          state.closeDialog();
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _submitting = false;
          _error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final globalError = context.select((AppState s) => s.globalError);
    final closeDialog = context.select((AppState s) => s.closeDialog);
    final theme = Theme.of(context);
    final media = MediaQuery.of(context);
    final name = _nameController.text.trim();
    final path = _pathController.text.trim();
    final canSubmit = name.isNotEmpty &&
        path.isNotEmpty &&
        !_submitting &&
        !_loading;

    return Stack(
      children: [
        ModalBarrier(
            color: theme.colorScheme.scrim.withValues(alpha: 0.4),
            dismissible: false),
        Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 560,
              maxHeight: media.size.height * 0.9,
            ),
            child: Card(
              margin: const EdgeInsets.all(24),
              elevation: 3,
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('New project', style: theme.textTheme.headlineSmall),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _nameController,
                      autofocus: true,
                      enabled: !_submitting,
                      decoration: const InputDecoration(
                        labelText: 'Name',
                        hintText: 'My project',
                        border: OutlineInputBorder(),
                      ),
                      textInputAction: TextInputAction.next,
                      onChanged: (_) => setState(() => _error = null),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _pathController,
                      enabled: !_submitting,
                      decoration: InputDecoration(
                        labelText: 'Path',
                        hintText: 'relative/project/path',
                        border: const OutlineInputBorder(),
                        suffixIcon: IconButton(
                          tooltip: 'Browse to this path',
                          icon: const Icon(Icons.refresh, size: 18),
                          onPressed: _submitting ? null : _jumpToTextPath,
                        ),
                      ),
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _submit(),
                      onChanged: (_) => setState(() => _error = null),
                    ),
                    const SizedBox(height: 8),
                    _BrowserHeader(
                      path: _currentPath,
                      onUp: _up,
                      onCrumb: _goTo,
                      enabled: !_loading && !_submitting,
                    ),
                    const SizedBox(height: 4),
                    Flexible(
                      child: Container(
                        constraints: const BoxConstraints(maxHeight: 320),
                        decoration: BoxDecoration(
                          border: Border.all(
                              color: theme.colorScheme.outlineVariant),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: _buildBrowser(theme),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: (_loading || _submitting) ? null : _selectCurrent,
                        icon: const Icon(Icons.check, size: 18),
                        label: const Text('Select current folder'),
                      ),
                    ),
                    if (globalError.isNotEmpty || _error != null) ...[
                      const SizedBox(height: 8),
                      Semantics(
                        liveRegion: true,
                        label: 'Error',
                        child: Text(
                          globalError.isNotEmpty ? globalError : _error!,
                          style: TextStyle(color: theme.colorScheme.error),
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: closeDialog,
                          child: const Text('Cancel'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: (canSubmit && !_submitting) ? _submit : null,
                          child: _submitting
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2))
                              : const Text('Create'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBrowser(ThemeData theme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            _error!,
            textAlign: TextAlign.center,
            style: TextStyle(color: theme.colorScheme.error),
          ),
        ),
      );
    }
    if (_entries.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            'No subfolders here',
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      );
    }
    return ListView.builder(
      shrinkWrap: true,
      itemCount: _entries.length,
      itemBuilder: (context, index) {
        final e = _entries[index];
        return ListTile(
          leading: Icon(Icons.folder,
              color: theme.colorScheme.primary, size: 20),
          title: Text(e.name, style: theme.textTheme.bodyMedium),
          dense: true,
          onTap: (_loading || _submitting) ? null : () => _enter(e.name),
        );
      },
    );
  }
}

class _BrowserHeader extends StatelessWidget {
  final String path;
  final VoidCallback onUp;
  final ValueChanged<int> onCrumb;
  final bool enabled;

  const _BrowserHeader({
    required this.path,
    required this.onUp,
    required this.onCrumb,
    required this.enabled,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final crumbs = path.isEmpty
        ? <String>['Home']
        : ['Home', ...path.split('/')];

    return Row(
      children: [
        TextButton.icon(
          onPressed: enabled ? onUp : null,
          icon: const Icon(Icons.arrow_upward, size: 18),
          label: const Text('Up'),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (var i = 0; i < crumbs.length; i++) ...[
                  if (i > 0)
                    Text(' / ', style: theme.textTheme.labelMedium),
                  InkWell(
                    onTap: enabled ? () => onCrumb(i - 1) : null,
                    child: Text(
                      crumbs[i],
                      style: theme.textTheme.labelMedium?.copyWith(
                            color: enabled
                                ? theme.colorScheme.primary
                                : theme.colorScheme.onSurfaceVariant,
                            fontWeight: i == crumbs.length - 1
                                ? FontWeight.w600
                                : FontWeight.normal,
                          ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _PermissionRequestDialog extends StatelessWidget {
  const _PermissionRequestDialog();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final req = state.pendingPermissionRequest;
    if (req == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final allowOnce = req.options.firstWhere(
      (o) => o.id == 'allow_once',
      orElse: () => req.options.first,
    );
    final otherOptions = req.options.where((o) => o.id != allowOnce.id).toList();

    return Stack(
      children: [
        ModalBarrier(
          color: theme.colorScheme.scrim.withValues(alpha: 0.4),
          dismissible: false,
        ),
        Center(
          child: AlertDialog(
            title: const Text('Permission request'),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420, maxHeight: 500),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      req.title,
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    if (req.input != null && req.input!.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          req.input!,
                          style: theme.textTheme.bodySmall
                              ?.copyWith(fontFamily: 'monospace'),
                        ),
                      ),
                    ],
                    const SizedBox(height: 20),
                    Text(
                      'Allow this action?',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FilledButton(
                    onPressed: () => state.respondToPermissionRequest(allowOnce.id),
                    child: Text(allowOnce.label ?? 'Allow once'),
                  ),
                  const SizedBox(height: 8),
                  if (otherOptions.isNotEmpty)
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final option in otherOptions)
                          OutlinedButton(
                            onPressed: () =>
                                state.respondToPermissionRequest(option.id),
                            child: Text(option.label ?? _displayKind(option.kind)),
                          ),
                      ],
                    ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () => state.respondToPermissionRequest(null),
                      child: const Text('Cancel'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _displayKind(String kind) {
    return switch (kind) {
      'AllowOnce' => 'Allow once',
      'AllowAlways' => 'Allow always',
      'RejectOnce' => 'Reject once',
      'RejectAlways' => 'Reject always',
      _ => kind,
    };
  }
}
