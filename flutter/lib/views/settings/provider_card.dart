part of '../settings_page.dart';

String _providerName(List<ProviderInfo> providers, String id) {
  for (final p in providers) {
    if (p.id == id) return p.name;
  }
  return id.isEmpty ? '—' : id;
}

class _ProviderCard extends StatelessWidget {
  final AppState state;
  const _ProviderCard({required this.state});

  @override
  Widget build(BuildContext context) {
    final user = state.user;
    final providers = state.providers;
    final l = l10n(context);

    return _SectionCard(
      title: l.provider,
      children: [
        _SettingsRow(
          label: l.provider,
          value: _providerName(providers, user?.providerId ?? ''),
          trailing: _ProviderDropdown(state: state),
        ),
        for (final p in providers) ...[
          const Divider(),
          _ProviderCommandRow(state: state, provider: p),
        ],
        const Divider(),
        _ProviderVersionRow(state: state),
      ],
    );
  }
}

class _ProviderVersionRow extends StatelessWidget {
  final AppState state;
  const _ProviderVersionRow({required this.state});

  @override
  Widget build(BuildContext context) {
    final l = l10n(context);
    final theme = Theme.of(context);
    final version = state.providerVersion;
    final installed = version?.installedVersion;
    final latest = version?.latestVersion;

    Widget trailing;
    if (version != null && version.updateAvailable && latest != null) {
      trailing = Chip(
        label: Text(l.providerUpdateAvailable(latest)),
        visualDensity: VisualDensity.compact,
      );
    } else if (installed != null && latest != null) {
      trailing = Text(
        l.providerUpToDate,
        style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      );
    } else {
      trailing = const SizedBox.shrink();
    }

    return _SettingsRow(
      label: l.providerVersion,
      value: installed ?? l.noValue,
      trailing: trailing,
    );
  }
}

class _ProviderDropdown extends StatelessWidget {
  final AppState state;
  const _ProviderDropdown({required this.state});

  @override
  Widget build(BuildContext context) {
    final providers = state.providers;
    final currentId = state.user?.providerId ?? '';
    if (providers.isEmpty) return const SizedBox.shrink();

    final ids = providers.map((p) => p.id).toSet();
    final effectiveId = ids.contains(currentId) ? currentId : providers.first.id;

    return DropdownButtonHideUnderline(
      child: DropdownButton<String>(
        value: effectiveId,
        isDense: true,
        items: providers
            .map((p) => DropdownMenuItem(
                  value: p.id,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ProviderIcon(providerId: p.id, size: 16),
                      const SizedBox(width: 8),
                      Text(p.name),
                    ],
                  ),
                ))
            .toList(),
        onChanged: (id) {
          if (id != null && id != currentId) {
            final user = state.user;
            if (user != null) {
              state.saveProvider(
                providerId: id,
                providerCommand: providerCommandFor(user, id),
              );
            }
          }
        },
      ),
    );
  }
}

class _ProviderCommandRow extends StatelessWidget {
  final AppState state;
  final ProviderInfo provider;
  const _ProviderCommandRow({required this.state, required this.provider});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            ProviderIcon(providerId: provider.id, size: 16),
            const SizedBox(width: 8),
            Text(provider.name, style: Theme.of(context).textTheme.labelLarge),
          ],
        ),
        const SizedBox(height: 6),
        _ProviderCommandField(state: state, providerId: provider.id),
      ],
    );
  }
}

class _ProviderCommandField extends StatefulWidget {
  final AppState state;
  final String providerId;
  const _ProviderCommandField({required this.state, required this.providerId});

  @override
  State<_ProviderCommandField> createState() => _ProviderCommandFieldState();
}

class _ProviderCommandFieldState extends State<_ProviderCommandField> {
  final _controller = TextEditingController();
  bool _testing = false;

  @override
  void initState() {
    super.initState();
    final user = widget.state.user;
    _controller.text = user == null
        ? defaultProviderCommand(widget.providerId)
        : providerCommandFor(user, widget.providerId);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String get _effectiveCommand {
    final command = _controller.text.trim();
    return command.isEmpty ? defaultProviderCommand(widget.providerId) : command;
  }

  Future<void> _save() async {
    final user = widget.state.user;
    if (user == null) return;
    final command = _effectiveCommand;
    _controller.text = command;
    await widget.state.saveProviderCommand(widget.providerId, command);
  }

  Future<void> _test() async {
    final user = widget.state.user;
    if (user == null) return;

    await _save();
    final command = _effectiveCommand;

    setState(() => _testing = true);
    try {
      await widget.state.testProvider(
        providerId: widget.providerId,
        command: command,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n(context).providerIsReachable)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n(context).providerTestFailed('$e'))),
        );
      }
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: TextField(
            controller: _controller,
            decoration: InputDecoration(
              labelText: l10n(context).command,
              hintText: l10n(context).providerCommandHint,
              isDense: true,
              border: const OutlineInputBorder(),
            ),
            onSubmitted: (_) => _save(),
          ),
        ),
        const SizedBox(width: 8),
        OutlinedButton(
          onPressed: _testing ? null : _test,
          child: _testing
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(l10n(context).test),
        ),
      ],
    );
  }
}
