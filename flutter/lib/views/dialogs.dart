import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import 'git_branch_dialog.dart';

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
      case DialogKind.newProject:
        return const _NewProjectDialog();
      case DialogKind.permissionRequest:
        return const _PermissionRequestDialog();
      case DialogKind.askRequest:
        return const _AskRequestDialog();
      case DialogKind.gitBranches:
        return const GitBranchDialog();
      case DialogKind.renameProject:
      case DialogKind.renameThread:
        return const _RenameDialog();
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
                        state.totpSecret,
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
  var _isAbsolute = false;
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

  String get _currentPath {
    if (_isAbsolute) {
      return _pathSegments.isEmpty ? '/' : '/${_pathSegments.join('/')}';
    }
    return _pathSegments.join('/');
  }

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
    _pathController.text = _currentPath.isEmpty ? '.' : _currentPath;
    if (_nameController.text.trim().isEmpty && _pathSegments.isNotEmpty) {
      _nameController.text = _pathSegments.last;
    }
    setState(() => _error = null);
  }

  void _jumpToTextPath() {
    setState(() => _error = null);
    final text = _pathController.text.trim();
    if (text.isEmpty) {
      _pathSegments.clear();
      _isAbsolute = false;
      _load();
      return;
    }
    // `~` is expanded by the backend; treat it as the home directory here.
    if (text == '~' || text.startsWith('~/')) {
      final rest = text == '~' ? '' : text.substring(2);
      _isAbsolute = false;
      _pathSegments
        ..clear()
        ..addAll(rest
            .split('/')
            .where((s) => s.isNotEmpty && s != '.')
            .toList());
      _load();
      return;
    }
    final normalized = text.replaceAll(RegExp(r'/+'), '/');
    if (normalized.contains('..')) {
      setState(() => _error = l10n(context).pathTraversalNotAllowed);
      return;
    }
    _isAbsolute = normalized.startsWith('/');
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
                    Text(l10n(context).newProject, style: theme.textTheme.headlineSmall),
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
                    TextField(
                      controller: _pathController,
                      enabled: !_submitting,
                      decoration: InputDecoration(
                        labelText: l10n(context).path,
                        hintText: l10n(context).projectPathHint,
                        border: const OutlineInputBorder(),
                        suffixIcon: IconButton(
                          tooltip: l10n(context).browseToThisPath,
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
                      isAbsolute: _isAbsolute,
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
                        label: Text(l10n(context).selectCurrentFolder),
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
                          onPressed: closeDialog,
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
            l10n(context).noSubfoldersHere,
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
  final bool isAbsolute;
  final VoidCallback onUp;
  final ValueChanged<int> onCrumb;
  final bool enabled;

  const _BrowserHeader({
    required this.path,
    this.isAbsolute = false,
    required this.onUp,
    required this.onCrumb,
    required this.enabled,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final segs = path
        .split('/')
        .where((s) => s.isNotEmpty)
        .toList();
    final rootLabel = isAbsolute ? l10n(context).root : l10n(context).home;
    final crumbs = <String>[rootLabel, ...segs];

    return Row(
      children: [
        TextButton.icon(
          onPressed: enabled ? onUp : null,
          icon: const Icon(Icons.arrow_upward, size: 18),
          label: Text(l10n(context).up),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (var i = 0; i < crumbs.length; i++) ...[
                  if (i > 0)
                    Text(l10n(context).breadcrumbSeparator,
                        style: theme.textTheme.labelMedium),
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

    if (req.options.isEmpty) {
      state.respondToPermissionRequest(null);
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
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

class _AskRequestDialog extends StatefulWidget {
  const _AskRequestDialog();

  @override
  State<_AskRequestDialog> createState() => _AskRequestDialogState();
}

class _AskRequestDialogState extends State<_AskRequestDialog> {
  final _formKey = GlobalKey<FormState>();
  final _answers = <String, dynamic>{};

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final req = state.pendingAskRequest;
    if (req == null || req.questions.isEmpty) {
      state.respondToAskRequest(null);
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);

    return Stack(
      children: [
        ModalBarrier(
          color: theme.colorScheme.scrim.withValues(alpha: 0.4),
          dismissible: false,
        ),
        Center(
          child: AlertDialog(
            title: Text(l10n(context).askRequest),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520, maxHeight: 600),
              child: Form(
                key: _formKey,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (req.message.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: Text(
                            req.message,
                            style: theme.textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                        ),
                      for (final q in req.questions) ...[
                        _buildField(context, q),
                        const SizedBox(height: 16),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => state.respondToAskRequest(null),
                child: Text(l10n(context).cancel),
              ),
              FilledButton(
                onPressed: () {
                  if (_formKey.currentState?.validate() ?? false) {
                    _formKey.currentState?.save();
                    final answers = Map<String, dynamic>.from(_answers)
                      ..removeWhere((k, v) => v == null || (v is List && v.isEmpty));
                    state.respondToAskRequest(answers);
                  }
                },
                child: Text(l10n(context).send),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildField(BuildContext context, AskQuestion q) {
    final theme = Theme.of(context);
    final label = q.prompt;
    final hint = q.description;

    if (q.isText) {
      return TextFormField(
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          border: const OutlineInputBorder(),
        ),
        validator: q.required
            ? (v) => (v == null || v.isEmpty) ? l10n(context).required : null
            : null,
        onSaved: (v) => _answers[q.id] = v,
      );
    }

    if (q.isNumber) {
      return TextFormField(
        keyboardType: TextInputType.number,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          border: const OutlineInputBorder(),
        ),
        validator: q.required
            ? (v) => (v == null || v.isEmpty) ? l10n(context).required : null
            : null,
        onSaved: (v) {
          if (v != null && v.isNotEmpty) {
            _answers[q.id] = num.tryParse(v) ?? v;
          }
        },
      );
    }

    if (q.isBoolean) {
      return FormField<bool>(
        initialValue: false,
        builder: (field) => SwitchListTile(
          title: Text(label),
          subtitle: hint != null ? Text(hint) : null,
          value: field.value ?? false,
          onChanged: (v) {
            field.didChange(v);
            _answers[q.id] = v;
          },
        ),
        onSaved: (v) => _answers[q.id] = v ?? false,
      );
    }

    if (q.isSingleSelect) {
      return DropdownButtonFormField<String>(
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          border: const OutlineInputBorder(),
        ),
        items: q.options
            .map((o) => DropdownMenuItem(value: o.value, child: Text(o.label)))
            .toList(),
        onChanged: (v) => setState(() => _answers[q.id] = v),
        validator: q.required
            ? (v) => v == null ? l10n(context).required : null
            : null,
        onSaved: (v) => _answers[q.id] = v,
      );
    }

    if (q.isMultiSelect) {
      return FormField<Set<String>>(
        initialValue: const <String>{},
        builder: (field) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: theme.textTheme.titleSmall),
            if (hint != null)
              Text(hint, style: theme.textTheme.bodySmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: q.options.map((o) {
                final selected = field.value?.contains(o.value) ?? false;
                return FilterChip(
                  label: Text(o.label),
                  selected: selected,
                  onSelected: (sel) {
                    final next = Set<String>.of(field.value ?? const <String>{});
                    if (sel) {
                      next.add(o.value);
                    } else {
                      next.remove(o.value);
                    }
                    field.didChange(next);
                    _answers[q.id] = next.toList();
                  },
                );
              }).toList(),
            ),
            if (field.hasError)
              Text(
                field.errorText!,
                style: TextStyle(color: theme.colorScheme.error),
              ),
          ],
        ),
        validator: q.required
            ? (v) => (v == null || v.isEmpty) ? l10n(context).required : null
            : null,
        onSaved: (v) => _answers[q.id] = (v ?? const <String>{}).toList(),
      );
    }

    return TextFormField(
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        border: const OutlineInputBorder(),
      ),
      onSaved: (v) => _answers[q.id] = v,
    );
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
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final l = l10n(context);
    final isProject = state.dialog == DialogKind.renameProject;
    final title = isProject ? l.renameProject : l.renameThread;
    final value = _controller.text.trim();
    final canSubmit = value.isNotEmpty &&
        value != state.renameInitialName &&
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
                        hintText: state.renameInitialName,
                        border: const OutlineInputBorder(),
                      ),
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _submit(state),
                      onChanged: (_) => setState(() {}),
                    ),
                    if (state.globalError.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text(
                        state.globalError,
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
  }
}
