import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/app_state.dart';
import '../utils/download.dart';
import '../utils/origin.dart';
import '../widgets/owner_badge.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final isNarrow = MediaQuery.of(context).size.width < 768;

    final sections = [
      _AccountSection(state: state),
      _ProviderCard(state: state),
      _DevicesSection(state: state),
      _PersonalizationSection(state: state),
      if (state.isOwner) _AccountsSection(state: state),
    ];
    final index = state.settingsTopicIndex.clamp(0, sections.length - 1);

    return Scaffold(
      appBar: AppBar(
        leading: isNarrow
            ? IconButton(
                icon: const Icon(Icons.menu),
                onPressed: () => Scaffold.of(context).openDrawer(),
              )
            : null,
        title: const Text('Settings'),
        backgroundColor: theme.colorScheme.surface,
        scrolledUnderElevation: 0,
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: sections[index],
          ),
        ),
      ),
    );
  }
}

class _AccountSection extends StatelessWidget {
  final AppState state;

  const _AccountSection({required this.state});

  Future<void> _confirmDisableTotp(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Disable 2FA?'),
        content: const Text(
          'This will remove TOTP-based two-factor authentication from your account. Are you sure?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Disable'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await state.disableTotp();
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = state.user;
    final username = user?.username ?? '';
    final totpEnabled = user?.totpEnabled ?? false;

    return _SectionCard(
      title: 'Account',
      children: [
        _SettingsRow(
          label: 'Username',
          value: username.isEmpty ? '—' : username,
        ),
        const Divider(),
        _SettingsRow(
          label: 'Two-factor authentication',
          value: totpEnabled ? 'Enabled' : 'Disabled',
          trailing: totpEnabled
              ? OutlinedButton.icon(
                  onPressed: () => _confirmDisableTotp(context),
                  icon: const Icon(Icons.lock_open_outlined, size: 18),
                  label: const Text('Disable 2FA'),
                )
              : FilledButton.icon(
                  onPressed: state.openTotpSetup,
                  icon: const Icon(Icons.lock_outline, size: 18),
                  label: const Text('Enable 2FA'),
                ),
        ),
      ],
    );
  }
}

String _providerName(List<ProviderInfo> providers, String id) {
  for (final p in providers) {
    if (p.id == id) return p.name;
  }
  return id.isEmpty ? '—' : id;
}

class _DevicesSection extends StatefulWidget {
  final AppState state;

  const _DevicesSection({required this.state});

  @override
  State<_DevicesSection> createState() => _DevicesSectionState();
}

class _DevicesSectionState extends State<_DevicesSection> {
  bool _creating = false;

  @override
  void initState() {
    super.initState();
    widget.state.loadDevices();
  }

  Future<void> _downloadPairing() async {
    setState(() => _creating = true);
    try {
      final serverUrl = kIsWeb
          ? currentOrigin()
          : (await widget.state.api.client.serverUrl ?? '');
      if (serverUrl.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not get server address')),
          );
        }
        return;
      }
      final pairing = await widget.state.createPairing(
        serverUrl: serverUrl,
        name: 'Devinorium native client',
      );
      downloadTextFile(pairing.toJsonString(), 'devinorium-pairing.json');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to create pairing: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  Future<void> _revoke(String token) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Revoke device?'),
        content: const Text('This device will be signed out immediately.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Revoke'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await widget.state.revokeDevice(token);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _SectionCard(
      title: 'Devices',
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(
                'Download a pairing file to set up the mobile or desktop app.',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
            const SizedBox(width: 12),
            _creating
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : FilledButton.icon(
                    onPressed: _downloadPairing,
                    icon: const Icon(Icons.download, size: 18),
                    label: const Text('Pair'),
                  ),
          ],
        ),
        const Divider(),
        ListenableBuilder(
          listenable: widget.state,
          builder: (context, child) {
            final devices = widget.state.devices;
            if (devices.isEmpty) {
              return Text(
                'No paired devices.',
                style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant),
              );
            }
            return ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: devices.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (_, i) => _DeviceRow(
                device: devices[i],
                onRevoke: _revoke,
              ),
            );
          },
        ),
      ],
    );
  }
}

class _DeviceRow extends StatelessWidget {
  final Device device;
  final void Function(String) onRevoke;

  const _DeviceRow({required this.device, required this.onRevoke});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final display = device.name?.isNotEmpty == true
        ? device.name!
        : 'Device ${device.tokenPrefix}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  display,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w500),
                ),
                Text(
                  device.isCurrent ? 'Current' : 'Paired',
                  style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          if (!device.isCurrent)
            IconButton(
              icon: const Icon(Icons.logout, size: 20),
              tooltip: 'Revoke',
              onPressed: () => onRevoke(device.deviceId),
            ),
        ],
      ),
    );
  }
}

class _ProviderCard extends StatelessWidget {
  final AppState state;
  const _ProviderCard({required this.state});

  @override
  Widget build(BuildContext context) {
    final user = state.user;
    final providers = state.providers;

    return _SectionCard(
      title: 'Provider',
      children: [
        _SettingsRow(
          label: 'Provider',
          value: _providerName(providers, user?.providerId ?? ''),
          trailing: _ProviderDropdown(state: state),
        ),
        const Divider(),
        _ProviderCommandField(state: state),
      ],
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
                  child: Text(p.name),
                ))
            .toList(),
        onChanged: (id) {
          if (id != null && id != currentId) {
            final user = state.user;
            if (user != null) {
              state.saveProvider(
                providerId: id,
                providerCommand: user.providerCommand,
              );
            }
          }
        },
      ),
    );
  }
}

class _ProviderCommandField extends StatefulWidget {
  final AppState state;
  const _ProviderCommandField({required this.state});

  @override
  State<_ProviderCommandField> createState() => _ProviderCommandFieldState();
}

class _ProviderCommandFieldState extends State<_ProviderCommandField> {
  final _controller = TextEditingController();
  bool _testing = false;

  @override
  void initState() {
    super.initState();
    final saved = (widget.state.user?.providerCommand ?? 'devin').trim();
    _controller.text = saved.isEmpty ? 'devin' : saved;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String get _effectiveCommand {
    final command = _controller.text.trim();
    return command.isEmpty ? 'devin' : command;
  }

  Future<void> _save() async {
    final user = widget.state.user;
    if (user == null) return;
    final command = _effectiveCommand;
    _controller.text = command;
    await widget.state.saveProvider(
      providerId: user.providerId,
      providerCommand: command,
    );
  }

  Future<void> _test() async {
    final user = widget.state.user;
    if (user == null) return;

    await _save();
    final command = _effectiveCommand;

    setState(() => _testing = true);
    try {
      await widget.state.testProvider(
        providerId: user.providerId,
        command: command,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Provider is reachable')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Provider test failed: $e')),
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
            decoration: const InputDecoration(
              labelText: 'Command',
              hintText: 'devin',
              isDense: true,
              border: OutlineInputBorder(),
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
              : const Text('Test'),
        ),
      ],
    );
  }
}

class _PersonalizationSection extends StatelessWidget {
  final AppState state;

  const _PersonalizationSection({required this.state});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _SectionCard(
      title: 'Personalization',
      children: [
        Row(
          children: [
            Text(
              'Theme',
              style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: SegmentedButton<ThemeMode>(
                segments: const [
                  ButtonSegment(
                    value: ThemeMode.light,
                    label: Text('Light'),
                  ),
                  ButtonSegment(
                    value: ThemeMode.dark,
                    label: Text('Dark'),
                  ),
                  ButtonSegment(
                    value: ThemeMode.system,
                    label: Text('System'),
                  ),
                ],
                selected: {state.themeMode},
                onSelectionChanged: (modes) {
                  if (modes.isNotEmpty) state.setThemeMode(modes.first);
                },
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _AccountsSection extends StatefulWidget {
  final AppState state;

  const _AccountsSection({required this.state});

  @override
  State<_AccountsSection> createState() => _AccountsSectionState();
}

class _AccountsSectionState extends State<_AccountsSection> {
  final _formKey = GlobalKey<FormState>();
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _obscure = true;
  bool _creating = false;

  @override
  void initState() {
    super.initState();
    widget.state.loadUsers();
  }

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _creating = true);
    await widget.state.createUser(
      username: _username.text,
      password: _password.text,
    );
    if (mounted) {
      setState(() => _creating = false);
      _username.clear();
      _password.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _SectionCard(
      title: 'Accounts',
      titleBadge: const OwnerBadge(),
      children: [
        Form(
          key: _formKey,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextFormField(
                  controller: _username,
                  decoration: const InputDecoration(
                    labelText: 'Username',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  textInputAction: TextInputAction.next,
                  enabled: !_creating,
                  validator: (v) =>
                      v == null || v.trim().isEmpty ? 'Required' : null,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextFormField(
                  controller: _password,
                  decoration: InputDecoration(
                    labelText: 'Password',
                    border: const OutlineInputBorder(),
                    isDense: true,
                    suffixIcon: IconButton(
                      icon: Icon(_obscure
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined),
                      onPressed: () =>
                          setState(() => _obscure = !_obscure),
                    ),
                  ),
                  obscureText: _obscure,
                  textInputAction: TextInputAction.done,
                  enabled: !_creating,
                  validator: (v) {
                    if (v == null || v.isEmpty) return 'Required';
                    if (v.length < 12) return 'At least 12 characters';
                    return null;
                  },
                  onFieldSubmitted: (_) => _submit(),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _creating ? null : _submit,
                child: _creating
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Create user'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        ListenableBuilder(
          listenable: widget.state,
          builder: (context, child) {
            final users = widget.state.users;
            if (users.isEmpty) {
              return Text(
                'No users yet.',
                style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant),
              );
            }
            return ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: users.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (_, i) => _UserRow(
                user: users[i],
                state: widget.state,
              ),
            );
          },
        ),
      ],
    );
  }
}

class _UserRow extends StatelessWidget {
  final User user;
  final AppState state;

  const _UserRow({required this.user, required this.state});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  user.username,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w500),
                ),
                Text(
                  user.role,
                  style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          Expanded(
            flex: 2,
            child: Row(
              children: [
                Icon(
                  Icons.verified_user_outlined,
                  size: 16,
                  color: user.totpEnabled
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
                Text(
                  user.totpEnabled ? 'On' : 'Off',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          if (!user.isOwner)
            Expanded(
              flex: 2,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Text(
                    user.disabled ? 'Disabled' : 'Active',
                    style: theme.textTheme.bodySmall,
                  ),
                  Switch(
                    value: user.disabled,
                    onChanged: (v) => state.setUserDisabled(user.id, v),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  final String title;
  final List<Widget> children;
  final Widget? titleBadge;
  const _SectionCard({
    required this.title,
    required this.children,
    this.titleBadge,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 1,
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(title,
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600)),
                if (titleBadge != null) ...[
                  const SizedBox(width: 8),
                  titleBadge!,
                ],
              ],
            ),
            const SizedBox(height: 16),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _SettingsRow extends StatelessWidget {
  final String label;
  final String value;
  final Widget trailing;
  const _SettingsRow({required this.label, required this.value, this.trailing = const SizedBox.shrink()});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant)),
              const SizedBox(height: 2),
              Text(value,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w500)),
            ],
          ),
        ),
        trailing,
      ],
    );
  }
}
