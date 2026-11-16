part of '../settings_page.dart';

class _AccountSection extends StatelessWidget {
  final AppState state;

  const _AccountSection({required this.state});

  // Enrollment changes require proof of account control: the current
  // password or, when TOTP is already enabled, a current code.
  Future<void> _promptTotpProof(
    BuildContext context, {
    required String title,
    String? message,
    required String confirmLabel,
    required Future<void> Function(String proof) action,
  }) async {
    final proof = await showDialog<String>(
      context: context,
      builder: (context) => _TotpProofDialog(
        title: title,
        message: message,
        confirmLabel: confirmLabel,
      ),
    );
    if (proof != null && proof.trim().isNotEmpty) {
      await action(proof.trim());
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
            label: l.password,
            value: '••••••••',
            trailing: OutlinedButton(
              onPressed: () => showDialog(
                context: context,
                builder: (_) => ChangePasswordDialog(state: state),
              ),
              child: Text(l.changePassword),
            ),
          ),
          const Divider(),
          _SettingsRow(
            label: l.twoFactorAuthentication,
            value: totpEnabled ? l.enabled : l.disabled,
            trailing: totpEnabled
                ? OutlinedButton.icon(
                    onPressed: () => _promptTotpProof(
                      context,
                      title: l.disable2faTitle,
                      message: l.disable2faConfirmation,
                      confirmLabel: l.disable2fa,
                      action: state.disableTotp,
                    ),
                    icon: const Icon(Icons.lock_open_outlined, size: 18),
                    label: Text(l.disable2fa),
                  )
                : FilledButton.icon(
                    onPressed: () => _promptTotpProof(
                      context,
                      title: l.enable2fa,
                      confirmLabel: l.enable2fa,
                      action: state.openTotpSetup,
                    ),
                    icon: const Icon(Icons.lock_outline, size: 18),
                    label: Text(l.enable2fa),
                  ),
          ),
        ],
      ],
    );
  }
}

class _TotpProofDialog extends StatefulWidget {
  const _TotpProofDialog({
    required this.title,
    this.message,
    required this.confirmLabel,
  });

  final String title;
  final String? message;
  final String confirmLabel;

  @override
  State<_TotpProofDialog> createState() => _TotpProofDialogState();
}

class _TotpProofDialogState extends State<_TotpProofDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = l10n(context);
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.message != null) ...[
            Text(widget.message!),
            const SizedBox(height: 12),
          ],
          Text(l.totpProofPrompt),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            autofocus: true,
            obscureText: true,
            decoration: InputDecoration(
              labelText: l.passwordOrTotpCode,
              border: const OutlineInputBorder(),
            ),
            onSubmitted: (v) => Navigator.of(context).pop(v),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
