import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/app_state.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final user = state.user;
    final username = user?.username ?? '';
    final totpEnabled = user?.totpEnabled ?? false;
    final isNarrow = MediaQuery.of(context).size.width < 768;

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
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              _SectionCard(
                title: 'Account',
                children: [
                  _SettingsRow(
                    label: 'Username',
                    value: username.isEmpty ? '—' : username,
                  ),
                  const Divider(),
                  _SettingsRow(
                    label: 'Provider',
                    value: _providerName(state.providers, user?.providerId ?? ''),
                    trailing: _ProviderDropdown(state: state),
                  ),
                  const Divider(),
                  _SettingsRow(
                    label: 'Two-factor authentication',
                    value: totpEnabled ? 'Enabled' : 'Disabled',
                    trailing: totpEnabled
                        ? OutlinedButton.icon(
                            onPressed: () => _confirmDisableTotp(context, state),
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
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmDisableTotp(BuildContext context, AppState state) async {
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
}

String _providerName(List<ProviderInfo> providers, String id) {
  for (final p in providers) {
    if (p.id == id) return p.name;
  }
  return id.isEmpty ? '—' : id;
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
            state.saveProvider(id);
          }
        },
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const _SectionCard({required this.title, required this.children});

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
            Text(title,
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w600)),
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
