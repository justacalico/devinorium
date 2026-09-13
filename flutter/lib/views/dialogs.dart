import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import 'folder_picker.dart';
import 'issue_panel.dart';
import 'merge_request_panel.dart';
import 'web_login_dialog.dart';

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
        final Widget dialog = switch (model.dialog) {
          DialogKind.none => const SizedBox.shrink(),
          DialogKind.totpSetup => const _TotpSetupDialog(),
          DialogKind.addProject => const _AddProjectDialog(),
          DialogKind.newProject => const _NewProjectDialog(),
          DialogKind.cloneRepo => const _CloneRepoDialog(),
          DialogKind.permissionRequest => const _PermissionRequestDialog(),
          DialogKind.mergeRequest =>
            (model.mergeRequestUrl == null || model.mergeRequestUrl!.isEmpty)
                ? const SizedBox.shrink()
                : MergeRequestPanel(url: model.mergeRequestUrl!),
          DialogKind.issue =>
            (model.issueUrl == null || model.issueUrl!.isEmpty)
                ? const SizedBox.shrink()
                : IssuePanel(url: model.issueUrl!),
          DialogKind.renameProject ||
          DialogKind.renameThread ||
          DialogKind.renameProjectGroup =>
            const _RenameDialog(),
          DialogKind.newProjectGroup => const _NewProjectGroupDialog(),
          DialogKind.manageProjectGroups =>
            const _ManageProjectGroupsDialog(),
          DialogKind.webLogin => const WebLoginDialog(),
        };
        // Remount per dialog kind so focus is re-established for each dialog.
        return _EscapeToDismiss(key: ValueKey(model.dialog), child: dialog);
      },
    );
  }
}

/// Dismisses the active dialog on Escape.
///
/// These dialogs are plain widgets in a [Stack], not routes, so Escape never
/// reaches them through the navigator. A hardware key handler is used instead
/// of focus propagation because text fields swallow Escape on Apple
/// platforms. The [Focus] node anchors the handler to this dialog and grabs
/// focus when nothing inside claimed it, so Escape keeps working even if
/// focus was sitting elsewhere in the app when the dialog opened.
class _EscapeToDismiss extends StatefulWidget {
  final Widget child;

  const _EscapeToDismiss({super.key, required this.child});

  @override
  State<_EscapeToDismiss> createState() => _EscapeToDismissState();
}

class _EscapeToDismissState extends State<_EscapeToDismiss> {
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleKey);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Pending autofocus requests resolve in a microtask, so wait for that
      // before deciding: the dialog's own autofocused field keeps focus when
      // it got one.
      scheduleMicrotask(() {
        if (!mounted || _focusNode.hasFocus) return;
        // Do not steal focus from a route covering this dialog.
        if (ModalRoute.of(context)?.isCurrent == false) return;
        _focusNode.requestFocus();
      });
    });
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKey);
    _focusNode.dispose();
    super.dispose();
  }

  bool _handleKey(KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.escape ||
        !_focusNode.hasFocus) {
      return false;
    }
    final state = context.read<AppState>();
    switch (state.dialog) {
      case DialogKind.none:
      case DialogKind.webLogin:
        // The web sign-in prompt has no cancel path; keep it on screen.
        return false;
      case DialogKind.permissionRequest:
        // Reject the request, not just close: the dialog reopens while a
        // permission request stays pending.
        unawaited(state.respondToPermissionRequest(null));
      default:
        state.closeDialog();
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      skipTraversal: true,
      includeSemantics: false,
      child: widget.child,
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

/// Entry point for adding a project: offers the sources (local folder or
/// remote clone) and forwards to the matching dialog.
class _AddProjectDialog extends StatelessWidget {
  const _AddProjectDialog();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = l10n(context);
    final state = context.read<AppState>();

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
                    Text(l.addProject, style: theme.textTheme.headlineSmall),
                    const SizedBox(height: 16),
                    _AddProjectSourceTile(
                      icon: Icons.create_new_folder_outlined,
                      title: l.addProjectLocalTitle,
                      description: l.addProjectLocalDescription,
                      onTap: () => unawaited(state.openNewProjectDialog()),
                    ),
                    const SizedBox(height: 8),
                    _AddProjectSourceTile(
                      icon: Icons.cloud_download_outlined,
                      title: l.cloneRepo,
                      description: l.addProjectCloneDescription,
                      onTap: state.openCloneRepoDialog,
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: state.closeDialog,
                          child: Text(l.cancel),
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

/// Dialog title with a back arrow that returns to the add-project source
/// picker.
class _AddProjectDialogTitle extends StatelessWidget {
  final String title;

  const _AddProjectDialogTitle({required this.title});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = context.read<AppState>();

    return Row(
      children: [
        IconButton(
          onPressed: state.openAddProjectDialog,
          icon: const Icon(Icons.arrow_back, size: 20),
          tooltip: l10n(context).back,
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.all(4),
          style: IconButton.styleFrom(
            foregroundColor: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            title,
            style: theme.textTheme.headlineSmall,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

class _AddProjectSourceTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;
  final VoidCallback onTap;

  const _AddProjectSourceTile({
    required this.icon,
    required this.title,
    required this.description,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          border: Border.all(color: theme.colorScheme.outlineVariant),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    description,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
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
      }
      // Close whichever add-project dialog is showing: the user may have
      // navigated back to the source picker while the create was in flight.
      if (state.globalError.isEmpty) {
        state.closeDialog();
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
                    _AddProjectDialogTitle(title: l10n(context).newProject),
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
    } else if (state.dialog == DialogKind.renameProjectGroup &&
        state.renameProjectGroupId != null) {
      await state.renameProjectGroup(state.renameProjectGroupId!, value);
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
        final title = switch (model.dialog) {
          DialogKind.renameProject => l.renameProject,
          DialogKind.renameProjectGroup => l.renameGroup,
          _ => l.renameThread,
        };
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
                    _AddProjectDialogTitle(title: l.cloneRepo),
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

class _NewProjectGroupDialog extends StatefulWidget {
  const _NewProjectGroupDialog();

  @override
  State<_NewProjectGroupDialog> createState() => _NewProjectGroupDialogState();
}

class _NewProjectGroupDialogState extends State<_NewProjectGroupDialog> {
  final _controller = TextEditingController();
  var _submitting = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit(AppState state) async {
    final name = _controller.text.trim();
    if (name.isEmpty) return;
    setState(() => _submitting = true);
    await state.createProjectGroup(name);
    if (mounted) setState(() => _submitting = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = l10n(context);
    final state = context.read<AppState>();
    final globalError = context.select((AppState s) => s.globalError);
    final canSubmit = _controller.text.trim().isNotEmpty && !_submitting;

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
                    Text(l.newGroup, style: theme.textTheme.headlineSmall),
                    const SizedBox(height: 16),
                    TextField(
                      key: const Key('new_group_name'),
                      controller: _controller,
                      autofocus: true,
                      enabled: !_submitting,
                      decoration: InputDecoration(
                        labelText: l.name,
                        hintText: l.groupNameHint,
                        border: const OutlineInputBorder(),
                      ),
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _submit(state),
                      onChanged: (_) => setState(() {}),
                    ),
                    if (globalError.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text(
                        globalError,
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
                          key: const Key('new_group_create'),
                          onPressed: canSubmit ? () => _submit(state) : null,
                          child: _submitting
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2),
                                )
                              : Text(l.create),
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

/// Lists every project group with rename/delete actions.
class _ManageProjectGroupsDialog extends StatelessWidget {
  const _ManageProjectGroupsDialog();

  Future<void> _confirmDelete(
    BuildContext context,
    AppState state,
    ProjectGroup group,
  ) async {
    final l = l10n(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(l.deleteGroupConfirm(group.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l.delete),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await state.deleteProjectGroup(group.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = l10n(context);
    final state = context.read<AppState>();
    final globalError = context.select((AppState s) => s.globalError);

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
                    Text(l.groups, style: theme.textTheme.headlineSmall),
                    const SizedBox(height: 16),
                    Selector<AppState,
                        ({List<ProjectGroup> groups, List<Project> projects})>(
                      selector: (_, s) => (
                        groups: s.projectGroups,
                        projects: s.projects,
                      ),
                      builder: (context, model, _) {
                        return Flexible(
                          child: ListView(
                            shrinkWrap: true,
                            children: [
                              for (final g in model.groups)
                                ListTile(
                                  key: Key('manage_group_${g.id}'),
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  leading: Icon(
                                    Icons.folder_outlined,
                                    color:
                                        theme.colorScheme.onSurfaceVariant,
                                  ),
                                  title: Text(
                                    g.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  subtitle: Text(
                                    l.groupProjectsCount(model.projects
                                        .where((p) => p.groupId == g.id)
                                        .length),
                                  ),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      IconButton(
                                        key: Key('rename_group_${g.id}'),
                                        tooltip: l.renameGroup,
                                        icon: const Icon(
                                            Icons.edit_outlined,
                                            size: 18),
                                        visualDensity:
                                            VisualDensity.compact,
                                        onPressed: () => state
                                            .openRenameProjectGroupDialog(
                                                g.id, g.name),
                                      ),
                                      IconButton(
                                        key: Key('delete_group_${g.id}'),
                                        tooltip: l.deleteGroup,
                                        icon: Icon(
                                          Icons.delete_outline,
                                          size: 18,
                                          color: theme.colorScheme.error,
                                        ),
                                        visualDensity:
                                            VisualDensity.compact,
                                        onPressed: () => _confirmDelete(
                                            context, state, g),
                                      ),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        key: const Key('manage_groups_new'),
                        onPressed: () =>
                            state.openNewProjectGroupDialog(fromManage: true),
                        icon: const Icon(Icons.add, size: 18),
                        label: Text(l.newGroup),
                      ),
                    ),
                    if (globalError.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        globalError,
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    ],
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: state.closeDialog,
                          child: Text(l.close),
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
