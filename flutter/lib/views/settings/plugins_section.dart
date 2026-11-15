part of 'package:devinorium_frontend/views/settings_page.dart';

/// Settings tab listing installed plugins with install, toggle, update,
/// and uninstall actions. Owner-only; project-scope plugins live under
/// `.devinorium/plugins` in a working directory and are read-only here.
class _PluginsSection extends StatefulWidget {
  const _PluginsSection();

  @override
  State<_PluginsSection> createState() => _PluginsSectionState();
}

class _PluginsSectionState extends State<_PluginsSection> {
  final _sourceCtrl = TextEditingController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<AppState>().loadPlugins();
    });
  }

  @override
  void dispose() {
    _sourceCtrl.dispose();
    super.dispose();
  }

  Future<void> _install() async {
    final source = _sourceCtrl.text.trim();
    if (source.isEmpty) return;
    setState(() => _busy = true);
    final err = await context.read<AppState>().installPlugin(source);
    if (!mounted) return;
    setState(() => _busy = false);
    if (err == null) {
      _sourceCtrl.clear();
    } else {
      context.read<AppState>().setGlobalError(err);
    }
  }

  Future<void> _run(Future<String?> Function() action) async {
    final err = await action();
    if (err != null && mounted) {
      context.read<AppState>().setGlobalError(err);
    }
  }

  Future<void> _uninstall(PluginInfo p) async {
    final l = AppLocalizations.of(context)!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.pluginUninstallConfirm(p.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l.uninstall),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    _run(() => context.read<AppState>().deletePlugin(p.name));
  }

  String _summary(PluginInfo p, AppLocalizations l) {
    final parts = <String>[
      if (p.skills.isNotEmpty) l.pluginSkills(p.skills.length),
      if (p.commands.isNotEmpty) l.pluginCommands(p.commands.length),
      if (p.mcpServers.isNotEmpty) l.pluginMcpServers(p.mcpServers.length),
      if (p.hooks.isNotEmpty) l.pluginHooks(p.hooks.length),
    ];
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final plugins = context.select<AppState, List<PluginInfo>>(
      (s) => s.plugins,
    );
    return _SectionCard(
      title: l.plugins,
      children: [
        Text(
          l.pluginsHint,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _sourceCtrl,
                decoration: InputDecoration(
                  hintText: l.pluginInstallField,
                  isDense: true,
                ),
                onSubmitted: (_) => _install(),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _busy ? null : _install,
              child: Text(l.install),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (plugins.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(l.pluginsEmpty, style: theme.textTheme.bodyMedium),
          )
        else
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: plugins.length,
            separatorBuilder: (context, index) => const Divider(height: 1),
            itemBuilder: (context, index) => _tile(plugins[index], l, theme),
          ),
      ],
    );
  }

  Widget _tile(PluginInfo p, AppLocalizations l, ThemeData theme) {
    final summary = _summary(p, l);
    return ListTile(
      key: Key('plugin_${p.name}'),
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.extension_outlined),
      title: Row(
        children: [
          Flexible(child: Text(p.name)),
          if (p.version.isNotEmpty) ...[
            const SizedBox(width: 8),
            Text(p.version, style: theme.textTheme.bodySmall),
          ],
        ],
      ),
      subtitle: [p.description, summary].every((s) => s.isEmpty)
          ? null
          : Text(
              [p.description, summary].where((s) => s.isNotEmpty).join('\n'),
            ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (p.manageable && p.install == 'git')
            IconButton(
              tooltip: l.pluginUpdate,
              icon: const Icon(Icons.refresh_outlined),
              onPressed: () => _run(
                () => context.read<AppState>().updatePlugin(p.name),
              ),
            ),
          if (p.manageable)
            IconButton(
              tooltip: l.uninstall,
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _uninstall(p),
            ),
          Switch(
            value: p.enabled,
            onChanged: p.manageable
                ? (v) => _run(
                    () => context.read<AppState>().setPluginEnabled(p.name, v),
                  )
                : null,
          ),
        ],
      ),
    );
  }
}
