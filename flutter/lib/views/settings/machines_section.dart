part of '../settings_page.dart';

/// Machines card under the Servers topic: the VNC endpoints an AI thread can
/// remote-control when a message references them with `@`. Everyone signed
/// in sees the list; only the owner can add, edit, delete, or probe entries.
/// The stored VNC password never comes back from the server — a lock badge
/// marks machines that have one.
class _MachinesSection extends StatefulWidget {
  const _MachinesSection();

  @override
  State<_MachinesSection> createState() => _MachinesSectionState();
}

class _MachinesSectionState extends State<_MachinesSection> {
  /// Per-machine probe results and in-flight probes, keyed by machine id.
  final Map<int, MachineTestResult> _testResults = {};
  final Set<int> _testing = {};

  /// The server the list was last seen on; switching clears probe state so
  /// a result cannot leak onto a different backend.
  String? _seenServerId;

  Future<void> _test(AppState state, Machine m) async {
    if (_testing.contains(m.id)) return;
    setState(() {
      _testing.add(m.id);
      _testResults.remove(m.id);
    });
    final serverId = state.activeServerId;
    final result = await state.testMachine(m.id);
    if (!mounted || state.activeServerId != serverId) return;
    setState(() {
      _testing.remove(m.id);
      _testResults[m.id] = result;
    });
  }

  Future<void> _delete(BuildContext context, AppState state, Machine m) async {
    final l = l10n(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(l.machineDeleteConfirm(m.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l.delete),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final error = await state.deleteMachine(m.id);
    if (error != null && context.mounted) {
      state.setGlobalError(error);
    }
  }

  Future<void> _openEditor(AppState state, [Machine? machine]) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _MachineDialog(state: state, machine: machine),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = l10n(context);
    final state = context.read<AppState>();

    return Selector<
      AppState,
      ({List<Machine> machines, bool isOwner, String? activeServerId})
    >(
      selector: (_, s) => (
        machines: s.machines,
        isOwner: s.isOwner,
        activeServerId: s.activeServerId,
      ),
      builder: (context, model, _) {
        if (model.activeServerId != _seenServerId) {
          _seenServerId = model.activeServerId;
          _testResults.clear();
          _testing.clear();
        }

        return _SectionCard(
          title: l.machines,
          children: [
            Text(
              l.machinesHint,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            if (model.machines.isEmpty)
              Text(l.machinesEmpty, style: theme.textTheme.bodyMedium)
            else
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: model.machines.length,
                separatorBuilder: (context, index) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final m = model.machines[index];
                  final result = _testResults[m.id];
                  final testing = _testing.contains(m.id);
                  return ListTile(
                    key: Key('machine_${m.id}'),
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.computer),
                    title: Row(
                      children: [
                        Flexible(
                          child: Text(
                            m.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (m.hasPassword) ...[
                          const SizedBox(width: 6),
                          Tooltip(
                            message: l.machineHasPassword,
                            child: Icon(
                              Icons.lock_outline,
                              size: 14,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ],
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${m.host}:${m.port}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontFamily: 'monospace',
                          ),
                        ),
                        if (result != null)
                          Text(
                            result.ok
                                ? l.machineTestOk(
                                    result.name ?? m.name,
                                    result.width ?? 0,
                                    result.height ?? 0,
                                  )
                                : l.machineTestFailed(result.error ?? ''),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: result.ok
                                  ? SemanticColors.of(context).success
                                  : theme.colorScheme.error,
                            ),
                          ),
                      ],
                    ),
                    trailing: model.isOwner
                        ? Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (testing)
                                const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              else
                                IconButton(
                                  key: Key('machine_test_${m.id}'),
                                  icon: const Icon(Icons.wifi_tethering),
                                  tooltip: l.machineTest,
                                  onPressed: () => unawaited(_test(state, m)),
                                ),
                              IconButton(
                                key: Key('machine_edit_${m.id}'),
                                icon: const Icon(Icons.edit_outlined),
                                tooltip: l.machineEdit,
                                onPressed: () =>
                                    unawaited(_openEditor(state, m)),
                              ),
                              IconButton(
                                key: Key('machine_delete_${m.id}'),
                                icon: const Icon(Icons.delete_outline),
                                tooltip: l.delete,
                                onPressed: () =>
                                    unawaited(_delete(context, state, m)),
                              ),
                            ],
                          )
                        : null,
                  );
                },
              ),
            if (!model.isOwner && model.machines.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  l.machinesOnlyOwner,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            if (model.isOwner) ...[
              const SizedBox(height: 8),
              FilledButton.tonal(
                key: const Key('machine_add'),
                onPressed: () => unawaited(_openEditor(state)),
                child: Text(l.machineAdd),
              ),
            ],
          ],
        );
      },
    );
  }
}

/// Create/edit dialog for one machine. On edit, a blank password keeps the
/// stored one and the clear checkbox removes it.
class _MachineDialog extends StatefulWidget {
  const _MachineDialog({required this.state, this.machine});

  final AppState state;
  final Machine? machine;

  @override
  State<_MachineDialog> createState() => _MachineDialogState();
}

class _MachineDialogState extends State<_MachineDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _password;
  bool _clearPassword = false;
  String _error = '';
  bool _loading = false;

  bool get _editing => widget.machine != null;

  @override
  void initState() {
    super.initState();
    final m = widget.machine;
    _name = TextEditingController(text: m?.name ?? '');
    _host = TextEditingController(text: m?.host ?? '');
    _port = TextEditingController(text: '${m?.port ?? 5900}');
    _password = TextEditingController();
  }

  @override
  void dispose() {
    _name.dispose();
    _host.dispose();
    _port.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _error = '';
      _loading = true;
    });
    try {
      final state = widget.state;
      final error = _editing
          ? await state.updateMachine(
              widget.machine!.id,
              name: _name.text,
              host: _host.text,
              port: int.parse(_port.text.trim()),
              password: _password.text,
              clearPassword: _clearPassword,
            )
          : await state.createMachine(
              name: _name.text,
              host: _host.text,
              port: int.parse(_port.text.trim()),
              password: _password.text,
            );
      if (!mounted) return;
      if (error != null) {
        setState(() => _error = error);
        return;
      }
      Navigator.of(context).pop();
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = l10n(context);

    String? validateRequired(String? value) {
      return value == null || value.trim().isEmpty ? l.required : null;
    }

    String? validateHost(String? value) {
      final trimmed = value?.trim() ?? '';
      if (trimmed.isEmpty) return l.required;
      if (trimmed.contains(' ')) return l.serverUrlInvalid;
      return null;
    }

    String? validatePort(String? value) {
      final parsed = int.tryParse(value?.trim() ?? '');
      if (parsed == null || parsed < 1 || parsed > 65535) {
        return l.tailscaleInvalidPort;
      }
      return null;
    }

    final hasStoredPassword = widget.machine?.hasPassword ?? false;

    return AlertDialog(
      title: Text(_editing ? l.machineEdit : l.machineAdd),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                key: const Key('machine_name'),
                controller: _name,
                decoration: InputDecoration(labelText: l.machineName),
                validator: validateRequired,
                enabled: !_loading,
              ),
              TextFormField(
                key: const Key('machine_host'),
                controller: _host,
                decoration: InputDecoration(
                  labelText: l.machineHost,
                  hintText: l.machineHostHint,
                ),
                validator: validateHost,
                enabled: !_loading,
              ),
              TextFormField(
                key: const Key('machine_port'),
                controller: _port,
                decoration: InputDecoration(labelText: l.machinePort),
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                validator: validatePort,
                enabled: !_loading,
              ),
              TextFormField(
                key: const Key('machine_password'),
                controller: _password,
                decoration: InputDecoration(
                  labelText: l.machinePassword,
                  helperText: _editing && hasStoredPassword
                      ? l.machinePasswordKeep
                      : null,
                ),
                obscureText: true,
                enabled: !_loading && !_clearPassword,
              ),
              if (_editing && hasStoredPassword)
                CheckboxListTile(
                  key: const Key('machine_clear_password'),
                  value: _clearPassword,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text(
                    l.machinePasswordClear,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  onChanged: _loading
                      ? null
                      : (v) => setState(() => _clearPassword = v ?? false),
                ),
              if (_error.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  _error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _loading ? null : () => Navigator.of(context).pop(),
          child: Text(l.cancel),
        ),
        TextButton(
          key: const Key('machine_save'),
          onPressed: _loading ? null : () => unawaited(_submit()),
          child: _loading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(_editing ? l.machineEdit : l.machineAdd),
        ),
      ],
    );
  }
}
