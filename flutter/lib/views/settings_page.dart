import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../utils/download.dart';
import '../utils/origin.dart';
import '../widgets/owner_badge.dart';
import 'create_user_dialog.dart';

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
        title: Text(l10n(context).settings),
        backgroundColor: theme.colorScheme.surface,
        scrolledUnderElevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: sections[index],
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
        title: Text(l10n(context).disable2faTitle),
        content: Text(
          l10n(context).disable2faConfirmation,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n(context).cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n(context).disable2fa),
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

    final l = l10n(context);
    return _SectionCard(
      title: l.account,
      children: [
        _SettingsRow(
          label: l.username,
          value: username.isEmpty ? '—' : username,
        ),
        const Divider(),
        _SettingsRow(
          label: l.twoFactorAuthentication,
          value: totpEnabled ? l.enabled : l.disabled,
          trailing: totpEnabled
              ? OutlinedButton.icon(
                  onPressed: () => _confirmDisableTotp(context),
                  icon: const Icon(Icons.lock_open_outlined, size: 18),
                  label: Text(l.disable2fa),
                )
              : FilledButton.icon(
                  onPressed: state.openTotpSetup,
                  icon: const Icon(Icons.lock_outline, size: 18),
                  label: Text(l.enable2fa),
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
    final l = l10n(context);
    setState(() => _creating = true);
    try {
      final serverUrl = kIsWeb
          ? currentOrigin()
          : (await widget.state.api.client.serverUrl ?? '');
      if (serverUrl.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l.couldNotGetServerAddress)),
          );
        }
        return;
      }
      final pairing = await widget.state.createPairing(
        serverUrl: serverUrl,
        name: l.appTitle,
      );
      downloadTextFile(pairing.toJsonString(), 'devinorium-pairing.json');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l.createPairingFailed('$e'))),
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
        title: Text(l10n(context).revokeDeviceTitle),
        content: Text(l10n(context).revokeDeviceBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n(context).cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n(context).revoke),
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
    final l = l10n(context);
    return _SectionCard(
      title: l.devices,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(
                l.pairingFileDescription,
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
                    label: Text(l.pair),
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
                l.noPairedDevices,
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
        : l10n(context).deviceToken(device.tokenPrefix);
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
                  device.isCurrent ? l10n(context).current : l10n(context).paired,
                  style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          if (!device.isCurrent)
            IconButton(
              icon: const Icon(Icons.logout, size: 20),
              tooltip: l10n(context).revoke,
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
    final l = l10n(context);

    return _SectionCard(
      title: l.provider,
      children: [
        _SettingsRow(
          label: l.provider,
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

class _PersonalizationSection extends StatelessWidget {
  final AppState state;

  const _PersonalizationSection({required this.state});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = l10n(context);
    return _SectionCard(
      title: l.personalization,
      children: [
        Row(
          children: [
            Text(
              l.theme,
              style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: SegmentedButton<ThemeMode>(
                segments: [
                  ButtonSegment(
                    value: ThemeMode.light,
                    label: Text(l.light),
                  ),
                  ButtonSegment(
                    value: ThemeMode.dark,
                    label: Text(l.dark),
                  ),
                  ButtonSegment(
                    value: ThemeMode.system,
                    label: Text(l.system),
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
        const SizedBox(height: 24),
        Row(
          children: [
            Text(
              l.language,
              style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: DropdownButton<String>(
                value: state.locale.languageCode,
                isExpanded: true,
                underline: const SizedBox.shrink(),
                items: [
                  DropdownMenuItem(value: 'en', child: Text(l.languageEnglish)),
                ],
                onChanged: (value) {
                  if (value != null) state.setLanguage(value);
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
  @override
  void initState() {
    super.initState();
    widget.state.loadUsers();
  }

  void _showCreateDialog() {
    showDialog(
      context: context,
      builder: (_) => CreateUserDialog(state: widget.state),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = l10n(context);
    return _SectionCard(
      title: l.manage,
      titleBadge: const OwnerBadge(),
      children: [
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: _showCreateDialog,
            child: Text(l.createUser),
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              flex: 3,
              child: Text(
                l.user,
                style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
            Expanded(
              flex: 2,
              child: Text(
                l.twoFactorShort,
                textAlign: TextAlign.right,
                style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
            Expanded(
              flex: 2,
              child: Text(
                l.active,
                textAlign: TextAlign.right,
                style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        ListenableBuilder(
          listenable: widget.state,
          builder: (context, child) {
            final users = widget.state.users;
            if (users.isEmpty) {
              return Text(
                l.noUsersYet,
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
              mainAxisAlignment: MainAxisAlignment.end,
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
                  user.totpEnabled ? l10n(context).on : l10n(context).off,
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          Expanded(
            flex: 2,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Switch(
                  value: !user.disabled,
                  onChanged: user.isOwner
                      ? null
                      : (v) => state.setUserDisabled(user.id, !v),
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
