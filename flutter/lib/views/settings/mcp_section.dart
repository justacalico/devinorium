part of '../settings_page.dart';

/// Picks an `.mcpb` bundle and returns its name and bytes, or null when the
/// user cancelled. A top-level variable so tests can swap in a fixture.
Future<({String name, Uint8List bytes})?> Function() mcpbBundlePicker =
    _defaultMcpbPicker;

Future<({String name, Uint8List bytes})?> _defaultMcpbPicker() async {
  final file = await FilePicker.pickFile(
    type: FileType.custom,
    allowedExtensions: const ['mcpb'],
    windowsOptions: const WindowsOptions(lockParentWindow: true),
    linuxOptions: const LinuxOptions(lockParentWindow: true),
  );
  if (file == null) return null;
  final bytes = await file.readAsBytes();
  return (name: file.name, bytes: bytes);
}

/// MCP servers card: the tool servers agents connect to at run start. The
/// whole list is edited client-side and written back in one shot, so add,
/// edit, delete, and the enable switch all share `saveMcpServers`.
/// Owner-only — a stdio entry is a command the server runs, and env values
/// and headers carry credentials.
class _McpSection extends StatefulWidget {
  const _McpSection();

  @override
  State<_McpSection> createState() => _McpSectionState();
}

class _McpSectionState extends State<_McpSection> {
  Future<void> _save(
    BuildContext context,
    AppState state,
    List<McpServerConfig> servers,
  ) async {
    final error = await state.saveMcpServers(servers);
    if (error != null && context.mounted) {
      state.setGlobalError(error);
    }
  }

  Future<void> _delete(
    BuildContext context,
    AppState state,
    McpServerConfig server,
  ) async {
    final l = l10n(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(l.mcpServerDeleteConfirm(server.name)),
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
    await _save(context, state, [
      for (final s in state.mcpServers)
        if (s.name != server.name) s,
    ]);
  }

  Future<void> _toggle(
    BuildContext context,
    AppState state,
    McpServerConfig server,
    bool enabled,
  ) async {
    await _save(context, state, [
      for (final s in state.mcpServers)
        s.name == server.name ? s.copyWith(enabled: enabled) : s,
    ]);
  }

  Future<void> _openEditor(AppState state, [McpServerConfig? server]) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _McpServerDialog(state: state, server: server),
    );
  }

  /// Pick a `.mcpb` file, inspect it on the server, and open the install
  /// dialog with the manifest's `user_config` fields.
  Future<void> _installBundle(AppState state) async {
    final l = l10n(context);
    try {
      final picked = await mcpbBundlePicker();
      if (picked == null || !mounted) return;
      final info = await state.api.inspectMcpb(
        filename: picked.name,
        bytes: picked.bytes,
      );
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => McpbInstallDialog(
          state: state,
          info: info,
          filename: picked.name,
          bytes: picked.bytes,
        ),
      );
    } catch (e) {
      if (mounted) {
        state.setGlobalError(l.mcpBundlePickFailed('$e'));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = l10n(context);
    final state = context.read<AppState>();

    return Selector<AppState, ({List<McpServerConfig> servers, bool isOwner})>(
      selector: (_, s) => (servers: s.mcpServers, isOwner: s.isOwner),
      builder: (context, model, _) {
        if (!model.isOwner) {
          return const SizedBox.shrink();
        }
        return _SectionCard(
          title: l.mcpServers,
          children: [
            Text(
              l.mcpServersHint,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            if (model.servers.isEmpty)
              Text(l.mcpServersEmpty, style: theme.textTheme.bodyMedium)
            else
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: model.servers.length,
                separatorBuilder: (context, index) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final s = model.servers[index];
                  return ListTile(
                    key: Key('mcp_${s.name}'),
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      s.isRemote ? Icons.cloud_outlined : Icons.terminal,
                    ),
                    title: Row(
                      children: [
                        Flexible(
                          child: Text(
                            s.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Tooltip(
                          message: s.transport,
                          child: Text(
                            s.transport.toUpperCase(),
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        if (!s.enabled) ...[
                          const SizedBox(width: 6),
                          Tooltip(
                            message: l.mcpServerDisabled,
                            child: Icon(
                              Icons.power_settings_new,
                              size: 14,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ],
                    ),
                    subtitle: Text(
                      s.endpoint,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                      ),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Switch(
                          key: Key('mcp_enable_${s.name}'),
                          value: s.enabled,
                          onChanged: (v) =>
                              unawaited(_toggle(context, state, s, v)),
                        ),
                        IconButton(
                          key: Key('mcp_edit_${s.name}'),
                          icon: const Icon(Icons.edit_outlined),
                          tooltip: l.mcpServerEdit,
                          onPressed: () => unawaited(_openEditor(state, s)),
                        ),
                        IconButton(
                          key: Key('mcp_delete_${s.name}'),
                          icon: const Icon(Icons.delete_outline),
                          tooltip: l.delete,
                          onPressed: () =>
                              unawaited(_delete(context, state, s)),
                        ),
                      ],
                    ),
                  );
                },
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                FilledButton.tonal(
                  key: const Key('mcp_add'),
                  onPressed: () => unawaited(_openEditor(state)),
                  child: Text(l.mcpServerAdd),
                ),
                OutlinedButton.icon(
                  key: const Key('mcp_install_bundle'),
                  icon: const Icon(Icons.upload_file_outlined, size: 18),
                  label: Text(l.mcpBundleInstall),
                  onPressed: () => unawaited(_installBundle(state)),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// Create/edit dialog for one MCP server. A transport selector swaps the
/// field set: `command`/`args`/`env` for stdio, `url`/`headers` for remote
/// servers. Arguments go one per line so values with spaces stay intact;
/// env and headers are `KEY=VALUE` lines.
class _McpServerDialog extends StatefulWidget {
  const _McpServerDialog({required this.state, this.server});

  final AppState state;
  final McpServerConfig? server;

  @override
  State<_McpServerDialog> createState() => _McpServerDialogState();
}

class _McpServerDialogState extends State<_McpServerDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _command;
  late final TextEditingController _args;
  late final TextEditingController _env;
  late final TextEditingController _url;
  late final TextEditingController _headers;
  late String _transport;
  late bool _enabled;
  String _error = '';
  bool _loading = false;

  bool get _editing => widget.server != null;
  bool get _isRemote =>
      _transport == McpServerConfig.transportHttp ||
      _transport == McpServerConfig.transportSse;

  @override
  void initState() {
    super.initState();
    final s = widget.server;
    _transport = s?.transport ?? McpServerConfig.transportStdio;
    _enabled = s?.enabled ?? true;
    _name = TextEditingController(text: s?.name ?? '');
    _command = TextEditingController(text: s?.command ?? '');
    _args = TextEditingController(text: (s?.args ?? const []).join('\n'));
    _env = TextEditingController(text: _pairsToLines(s?.env));
    _url = TextEditingController(text: s?.url ?? '');
    _headers = TextEditingController(text: _pairsToLines(s?.headers));
  }

  static String _pairsToLines(Map<String, String>? pairs) =>
      (pairs ?? const {}).entries.map((e) => '${e.key}=${e.value}').join('\n');

  static Map<String, String> _linesToPairs(String text) => {
    for (final line in text.split('\n'))
      if (line.trim().isNotEmpty && line.contains('='))
        line.substring(0, line.indexOf('=')).trim(): line
            .substring(line.indexOf('=') + 1)
            .trim(),
  };

  @override
  void dispose() {
    _name.dispose();
    _command.dispose();
    _args.dispose();
    _env.dispose();
    _url.dispose();
    _headers.dispose();
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
      final server = McpServerConfig(
        name: _name.text.trim(),
        enabled: _enabled,
        transport: _transport,
        command: _isRemote ? '' : _command.text.trim(),
        args: _isRemote
            ? const []
            : [
                for (final line in _args.text.split('\n'))
                  if (line.trim().isNotEmpty) line.trim(),
              ],
        env: _isRemote ? const {} : _linesToPairs(_env.text),
        url: _isRemote ? _url.text.trim() : '',
        headers: _isRemote ? _linesToPairs(_headers.text) : const {},
      );
      final replacing = widget.server?.name;
      final error = await state.saveMcpServers([
        for (final s in state.mcpServers)
          if (s.name != replacing && s.name != server.name) s,
        server,
      ]);
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

    String? validateRequired(String? value) =>
        value == null || value.trim().isEmpty ? l.required : null;

    String? validateName(String? value) {
      final v = value?.trim() ?? '';
      if (v.isEmpty) return l.required;
      final valid =
          v.length <= 64 &&
          RegExp(r'^[A-Za-z0-9][A-Za-z0-9_\-.]*$').hasMatch(v);
      if (!valid) return l.mcpServerNameInvalid;
      final taken = widget.state.mcpServers.any(
        (s) => s.name == v && s.name != widget.server?.name,
      );
      return taken ? l.mcpServerNameTaken : null;
    }

    String? validateUrl(String? value) {
      final v = value?.trim() ?? '';
      if (v.isEmpty) return l.required;
      final uri = Uri.tryParse(v);
      final ok =
          uri != null &&
          (uri.scheme == 'http' || uri.scheme == 'https') &&
          uri.host.isNotEmpty;
      return ok ? null : l.mcpServerUrlInvalid;
    }

    return AlertDialog(
      title: Text(_editing ? l.mcpServerEdit : l.mcpServerAdd),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SegmentedButton<String>(
                key: const Key('mcp_transport'),
                segments: [
                  ButtonSegment(
                    value: McpServerConfig.transportStdio,
                    label: const Text('stdio'),
                    icon: const Icon(Icons.terminal, size: 16),
                  ),
                  ButtonSegment(
                    value: McpServerConfig.transportHttp,
                    label: const Text('HTTP'),
                    icon: const Icon(Icons.cloud_outlined, size: 16),
                  ),
                  ButtonSegment(
                    value: McpServerConfig.transportSse,
                    label: const Text('SSE'),
                    icon: const Icon(Icons.rss_feed, size: 16),
                  ),
                ],
                selected: {_transport},
                onSelectionChanged: _loading
                    ? null
                    : (s) => setState(() => _transport = s.first),
              ),
              const SizedBox(height: 8),
              TextFormField(
                key: const Key('mcp_name'),
                controller: _name,
                decoration: InputDecoration(
                  labelText: l.mcpServerName,
                  hintText: 'github',
                ),
                validator: validateName,
                enabled: !_loading,
              ),
              if (_isRemote) ...[
                TextFormField(
                  key: const Key('mcp_url'),
                  controller: _url,
                  decoration: InputDecoration(
                    labelText: l.mcpServerUrl,
                    hintText: 'https://mcp.example.com/mcp',
                  ),
                  validator: validateUrl,
                  enabled: !_loading,
                ),
                TextFormField(
                  key: const Key('mcp_headers'),
                  controller: _headers,
                  decoration: InputDecoration(
                    labelText: l.mcpServerHeaders,
                    helperText: l.mcpServerPairsHint,
                  ),
                  maxLines: 3,
                  enabled: !_loading,
                ),
              ] else ...[
                TextFormField(
                  key: const Key('mcp_command'),
                  controller: _command,
                  decoration: InputDecoration(
                    labelText: l.mcpServerCommand,
                    hintText: 'npx',
                  ),
                  validator: validateRequired,
                  enabled: !_loading,
                ),
                TextFormField(
                  key: const Key('mcp_args'),
                  controller: _args,
                  decoration: InputDecoration(
                    labelText: l.mcpServerArgs,
                    helperText: l.mcpServerArgsHint,
                    hintText: '-y\n@company/mcp-server',
                  ),
                  maxLines: 3,
                  enabled: !_loading,
                ),
                TextFormField(
                  key: const Key('mcp_env'),
                  controller: _env,
                  decoration: InputDecoration(
                    labelText: l.mcpServerEnv,
                    helperText: l.mcpServerPairsHint,
                    hintText: 'API_KEY=…',
                  ),
                  maxLines: 3,
                  enabled: !_loading,
                ),
              ],
              SwitchListTile(
                key: const Key('mcp_enabled'),
                value: _enabled,
                contentPadding: EdgeInsets.zero,
                title: Text(
                  l.mcpServerEnabled,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                onChanged: _loading
                    ? null
                    : (v) => setState(() => _enabled = v),
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
        FilledButton(
          key: const Key('mcp_save'),
          onPressed: _loading ? null : _submit,
          child: Text(l.save),
        ),
      ],
    );
  }
}

/// Install dialog for an `.mcpb` bundle after the server inspected it:
/// shows the manifest identity and warnings, then one input per
/// `user_config` field (sensitive values masked, `multiple` one per line,
/// boolean a switch). Installing uploads the bundle again with the values
/// and the response replaces the server list.
class McpbInstallDialog extends StatefulWidget {
  const McpbInstallDialog({
    super.key,
    required this.state,
    required this.info,
    required this.filename,
    required this.bytes,
  });

  final AppState state;
  final McpbInfo info;
  final String filename;
  final Uint8List bytes;

  @override
  State<McpbInstallDialog> createState() => _McpbInstallDialogState();
}

class _McpbInstallDialogState extends State<McpbInstallDialog> {
  final _formKey = GlobalKey<FormState>();
  final _controllers = <String, TextEditingController>{};
  final _bools = <String, bool>{};
  String _error = '';
  bool _loading = false;

  McpbInfo get info => widget.info;

  @override
  void initState() {
    super.initState();
    for (final f in info.userConfig) {
      if (f.isBoolean) {
        _bools[f.key] = f.defaultValue == true;
      } else {
        final d = f.defaultValue;
        final text = switch (d) {
          List l => l.map((e) => '$e').join('\n'),
          _ => d?.toString() ?? '',
        };
        _controllers[f.key] = TextEditingController(text: text);
      }
    }
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// Build the `config` JSON for the install call. Optional empty fields are
  /// omitted so the manifest's own default can still apply.
  Map<String, dynamic> _collectConfig() {
    final out = <String, dynamic>{};
    for (final f in info.userConfig) {
      if (f.isBoolean) {
        out[f.key] = _bools[f.key] ?? false;
        continue;
      }
      final text = _controllers[f.key]!.text.trim();
      if (f.multiple) {
        final items = [
          for (final line in text.split('\n'))
            if (line.trim().isNotEmpty) line.trim(),
        ];
        // An empty list would clobber the manifest default; omit it.
        if (items.isNotEmpty) out[f.key] = items;
        continue;
      }
      if (text.isEmpty) continue;
      out[f.key] = f.isNumber ? num.tryParse(text) ?? text : text;
    }
    return out;
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _error = '';
      _loading = true;
    });
    try {
      final error = await widget.state.installMcpb(
        widget.filename,
        widget.bytes,
        _collectConfig(),
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

  String? _validateField(McpbUserConfig f, String? value) {
    final l = l10n(context);
    final text = value?.trim() ?? '';
    if (f.multiple) {
      final items = [
        for (final line in text.split('\n'))
          if (line.trim().isNotEmpty) line,
      ];
      if (f.required && items.isEmpty) return l.required;
      return null;
    }
    if (text.isEmpty) return f.required ? l.required : null;
    if (f.isNumber) {
      final n = num.tryParse(text);
      if (n == null) return l.mcpBundleNumberInvalid;
      if (f.min != null && n < f.min!) {
        return '${l.mcpBundleNumberInvalid} (≥ ${f.min})';
      }
      if (f.max != null && n > f.max!) {
        return '${l.mcpBundleNumberInvalid} (≤ ${f.max})';
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = l10n(context);
    final meta = [
      if (info.version.isNotEmpty) 'v${info.version}',
      if (info.author.isNotEmpty) info.author,
      if (info.serverType.isNotEmpty) info.serverType,
      if (info.license.isNotEmpty) info.license,
    ].join(' · ');

    return AlertDialog(
      title: Text(info.displayName.isNotEmpty ? info.displayName : info.name),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (meta.isNotEmpty)
                Text(
                  meta,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              if (info.description.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(info.description),
                ),
              if (info.warnings.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  l.mcpBundleWarnings,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
                for (final w in info.warnings)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.warning_amber,
                          size: 16,
                          color: theme.colorScheme.error,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(w, style: theme.textTheme.bodySmall),
                        ),
                      ],
                    ),
                  ),
              ],
              if (info.userConfig.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(l.mcpBundleConfig, style: theme.textTheme.labelLarge),
              ],
              for (final f in info.userConfig) ...[
                const SizedBox(height: 8),
                if (f.isBoolean)
                  SwitchListTile(
                    key: Key('mcpb_cfg_${f.key}'),
                    value: _bools[f.key] ?? false,
                    contentPadding: EdgeInsets.zero,
                    title: Text(f.title, style: theme.textTheme.bodyMedium),
                    subtitle: f.description.isEmpty
                        ? null
                        : Text(f.description),
                    onChanged: _loading
                        ? null
                        : (v) => setState(() => _bools[f.key] = v),
                  )
                else
                  TextFormField(
                    key: Key('mcpb_cfg_${f.key}'),
                    controller: _controllers[f.key],
                    decoration: InputDecoration(
                      labelText: f.required ? '${f.title} *' : f.title,
                      helperText: [
                        if (f.description.isNotEmpty) f.description,
                        if (f.multiple) l.mcpBundleMultipleHint,
                      ].join('\n'),
                    ),
                    obscureText: f.sensitive,
                    // Obscured fields must stay single-line, so a sensitive
                    // multi-value field collapses to one line.
                    maxLines: f.multiple && !f.sensitive ? 3 : 1,
                    keyboardType: f.isNumber
                        ? TextInputType.number
                        : TextInputType.text,
                    validator: (v) => _validateField(f, v),
                    enabled: !_loading,
                  ),
              ],
              if (_error.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(_error, style: TextStyle(color: theme.colorScheme.error)),
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
        FilledButton(
          key: const Key('mcpb_install'),
          onPressed: _loading ? null : _submit,
          child: Text(l.mcpBundleInstallAction),
        ),
      ],
    );
  }
}
