part of '../settings_page.dart';

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
    // The bundled local server authenticates by token, not password, so
    // two-factor settings have no effect on it.
    final isLocal = state.multiServerState.activeProfile?.isLocal ?? false;

    final l = l10n(context);
    return _SectionCard(
      title: l.account,
      children: [
        _SettingsRow(
          label: l.username,
          value: username.isEmpty ? '—' : username,
        ),
        if (!isLocal) ...[
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
      ],
    );
  }
}
