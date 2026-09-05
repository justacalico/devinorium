import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import 'folder_picker.dart';
import 'issue_panel.dart';
import 'merge_request_panel.dart';

class DialogLayer extends StatelessWidget {
  const DialogLayer({super.key});

  @override
  Widget build(BuildContext context) {
    return Selector<AppState, ({
      DialogKind dialog,
      String? mergeRequestUrl,
      String? issueUrl,
    })>(
      selector: (_, s) => (
        dialog: s.dialog,
        mergeRequestUrl: s.mergeRequestUrl,
        issueUrl: s.issueUrl,
      ),
      builder: (context, model, _) {
        switch (model.dialog) {
          case DialogKind.none:
            return const SizedBox.shrink();
          case DialogKind.totpSetup:
            return const _TotpSetupDialog();
          case DialogKind.newProject:
            return const _NewProjectDialog();
          case DialogKind.cloneRepo:
            return const _CloneRepoDialog();
          case DialogKind.permissionRequest:
            return const _PermissionRequestDialog();
          case DialogKind.mergeRequest:
            final url = model.mergeRequestUrl;
            if (url == null || url.isEmpty) return const SizedBox.shrink();
            return MergeRequestPanel(url: url);
          case DialogKind.issue:
            final issueUrl = model.issueUrl;
            if (issueUrl == null || issueUrl.isEmpty) {
              return const SizedBox.shrink();
            }
            return IssuePanel(url: issueUrl);
          case DialogKind.renameProject:
          case DialogKind.renameThread:
            return const _RenameDialog();
        }
      },
    );
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
    final theme = Theme.of(context);
    final state = context.read<AppState>();

    return Selector<AppState, String>(
      selector: (_, s) => s.totpSecret,
      builder: (context, totpSecret, _) {
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
                    Text(l10n(context).enable2fa, style: theme.textTheme.headlineSmall),
                    const SizedBox(height: 12),
                    Text(
                      l10n(context).totpSetupInstructions,
                    ),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHigh,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: SelectableText(
                        totpSecret,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(fontFamily: 'monospace'),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _codeController,
                      decoration: InputDecoration(
                        labelText: l10n(context).totpCode,
                        hintText: l10n(context).totpHint,
                        border: const OutlineInputBorder(),
                      ),
                      keyboardType: TextInputType.number,
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: state.closeDialog,
                          child: Text(l10n(context).cancel),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: () {
                            state.verifyTotp(_codeController.text.trim());
                          },
                          child: Text(l10n(context).verify),
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
  });
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
  var _submitting = false;
  String? _error;

  @override
  void dispose() {
    _nameController.dispose();
    _pathController.dispose();
    super.dispose();
  }

  void _onPathSelected(String path, bool isHomeRoot) {
    if (!isHomeRoot && _nameController.text.trim().isEmpty) {
      final parts = path.split('/').where((s) => s.isNotEmpty).toList();
      if (parts.isNotEmpty) {
        _nameController.text = parts.last;
      }
    }
    setState(() => _error = null);
  }

  Future<void> _submit() async {
    final name = _nameController.text.trim();
    final path = _pathController.text.trim();
    if (name.isEmpty || path.isEmpty) {
      setState(() => _error = l10n(context).nameAndPathRequired);
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
    final state = context.read<AppState>();
    final theme = Theme.of(context);
    final media = MediaQuery.of(context);
    final name = _nameController.text.trim();
    final path = _pathController.text.trim();
    final canSubmit = name.isNotEmpty && path.isNotEmpty && !_submitting;

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
                    Text(l10n(context).newProject,
                        style: theme.textTheme.headlineSmall),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _nameController,
                      autofocus: true,
                      enabled: !_submitting,
                      decoration: InputDecoration(
                        labelText: l10n(context).name,
                        hintText: l10n(context).myProjectHint,
                        border: const OutlineInputBorder(),
                      ),
                      textInputAction: TextInputAction.next,
                      onChanged: (_) => setState(() => _error = null),
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: FolderPicker(
                        api: context.read<AppState>().api,
                        controller: _pathController,
                        homePrefix: '.',
                        onSelect: _onPathSelected,
                      ),
                    ),
                    if (globalError.isNotEmpty || _error != null) ...[
                      const SizedBox(height: 8),
                      Semantics(
                        liveRegion: true,
                        label: l10n(context).error,
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
                          onPressed: state.closeDialog,
                          child: Text(l10n(context).cancel),
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
                              : Text(l10n(context).create),
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

class _PermissionRequestDialog extends StatelessWidget {
  const _PermissionRequestDialog();

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final theme = Theme.of(context);

    return Selector<AppState, PermissionRequest?>(
      selector: (_, s) => s.pendingPermissionRequest,
      builder: (context, req, _) {
        if (req == null) return const SizedBox.shrink();

        if (req.options.isEmpty) {
          state.respondToPermissionRequest(null);
          return const SizedBox.shrink();
        }
    final allowOnce = req.options.firstWhere(
      (o) => o.kind == 'AllowOnce',
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
            title: Text(l10n(context).permissionRequest),
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
                      l10n(context).allowThisAction,
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
                    child: Text(allowOnce.label ?? l10n(context).allowOnce),
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
                            child: Text(option.label ?? _displayKind(context, option.kind)),
                          ),
                      ],
                    ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () => state.respondToPermissionRequest(null),
                      child: Text(l10n(context).cancel),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  });
  }

  String _displayKind(BuildContext context, String kind) {
    return switch (kind) {
      'AllowOnce' => l10n(context).allowOnce,
      'AllowAlways' => l10n(context).allowAlways,
      'RejectOnce' => l10n(context).rejectOnce,
      'RejectAlways' => l10n(context).rejectAlways,
      _ => kind,
    };
  }
}

class _RenameDialog extends StatefulWidget {
  const _RenameDialog();

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  final _controller = TextEditingController();
  var _submitting = false;

  @override
  void initState() {
    super.initState();
    final state = context.read<AppState>();
    _controller.text = state.renameInitialName;
    _controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _controller.text.length,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit(AppState state) async {
    final value = _controller.text.trim();
    if (value.isEmpty || value == state.renameInitialName) return;

    setState(() => _submitting = true);
    if (state.dialog == DialogKind.renameProject && state.renameProjectId != null) {
      await state.renameProject(state.renameProjectId!, value);
    } else if (state.dialog == DialogKind.renameThread && state.renameThreadId != null) {
      await state.renameThread(state.renameThreadId!, value);
    }
    if (mounted) setState(() => _submitting = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = l10n(context);
    final state = context.read<AppState>();

    return Selector<AppState, ({
      DialogKind dialog,
      String renameInitialName,
      String globalError,
    })>(
      selector: (_, s) => (
        dialog: s.dialog,
        renameInitialName: s.renameInitialName,
        globalError: s.globalError,
      ),
      builder: (context, model, _) {
        final isProject = model.dialog == DialogKind.renameProject;
        final title = isProject ? l.renameProject : l.renameThread;
        final value = _controller.text.trim();
        final canSubmit = value.isNotEmpty &&
            value != model.renameInitialName &&
            !_submitting;

        return Stack(
      children: [
        ModalBarrier(
          color: theme.colorScheme.scrim.withValues(alpha: 0.4),
          dismissible: false,
        ),
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
                    Text(title, style: theme.textTheme.headlineSmall),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _controller,
                      autofocus: true,
                      enabled: !_submitting,
                      decoration: InputDecoration(
                        labelText: l.newName,
                        hintText: model.renameInitialName,
                        border: const OutlineInputBorder(),
                      ),
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _submit(state),
                      onChanged: (_) => setState(() {}),
                    ),
                    if (model.globalError.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text(
                        model.globalError,
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    ],
                    const SizedBox(height: 20),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: _submitting ? null : state.closeDialog,
                          child: Text(l.cancel),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: canSubmit ? () => _submit(state) : null,
                          child: _submitting
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : Text(l.save),
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
  });
  }
}

class _CloneRepoDialog extends StatefulWidget {
  const _CloneRepoDialog();

  @override
  State<_CloneRepoDialog> createState() => _CloneRepoDialogState();
}

class _CloneRepoDialogState extends State<_CloneRepoDialog> {
  final _urlController = TextEditingController();

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = l10n(context);
    final state = context.read<AppState>();

    return Selector<AppState, ({
      String? cloneRepoResult,
      bool cloningRepo,
      String globalError,
    })>(
      selector: (_, s) => (
        cloneRepoResult: s.cloneRepoResult,
        cloningRepo: s.cloningRepo,
        globalError: s.globalError,
      ),
      builder: (context, model, _) {
        final result = model.cloneRepoResult;
        final hasResult = result != null && result.isNotEmpty;

        return Stack(
      children: [
        ModalBarrier(
          color: theme.colorScheme.scrim.withValues(alpha: 0.4),
          dismissible: false,
        ),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Card(
              margin: const EdgeInsets.all(24),
              elevation: 3,
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(l.cloneRepo, style: theme.textTheme.headlineSmall),
                    const SizedBox(height: 8),
                    Text(l.cloneRepoDescription),
                    const SizedBox(height: 16),
                    if (!hasResult)
                      TextField(
                        controller: _urlController,
                        autofocus: true,
                        enabled: !model.cloningRepo,
                        decoration: InputDecoration(
                          labelText: l.cloneRepoUrlLabel,
                          hintText: 'https://gitlab.com/owner/repo.git',
                          border: const OutlineInputBorder(),
                        ),
                        keyboardType: TextInputType.url,
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => _clone(state),
                      ),
                    if (hasResult) ...[
                      const SizedBox(height: 8),
                      SelectableText(result),
                    ],
                    if (model.globalError.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text(
                        model.globalError,
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    ],
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: state.closeDialog,
                          child: Text(hasResult ? l.close : l.cancel),
                        ),
                        const SizedBox(width: 8),
                        if (hasResult)
                          FilledButton(
                            onPressed: () =>
                                state.openClonedProjectByPath(result),
                            child: Text(l.cloneRepoOpenProject),
                          )
                        else
                          FilledButton(
                            onPressed:
                                model.cloningRepo ? null : () => _clone(state),
                            child: model.cloningRepo
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  )
                                : Text(l.cloneRepoButton),
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
  });
  }

  Future<void> _clone(AppState state) async {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;
    await state.cloneRepo(url);
  }
}
