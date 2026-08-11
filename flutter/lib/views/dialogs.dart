import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';

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
      case DialogKind.invites:
        return const _InvitesDialog();
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
                    Text('Enable 2FA', style: theme.textTheme.headlineSmall),
                    const SizedBox(height: 12),
                    const Text(
                      'Scan this secret in your authenticator app, then enter the current code.',
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
                      decoration: const InputDecoration(
                        labelText: 'TOTP code',
                        hintText: '000000',
                        border: OutlineInputBorder(),
                      ),
                      keyboardType: TextInputType.number,
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: state.closeDialog,
                          child: const Text('Cancel'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: () {
                            state.verifyTotp(_codeController.text.trim());
                          },
                          child: const Text('Verify'),
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

class _InvitesDialog extends StatelessWidget {
  const _InvitesDialog();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final invites = state.invites;
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
                    Row(
                      children: [
                        Expanded(
                          child: Text('Invite tokens',
                              style: theme.textTheme.headlineSmall),
                        ),
                        IconButton.filled(
                          onPressed: state.createInvite,
                          icon: const Icon(Icons.add),
                          tooltip: 'Create invite',
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Share a token so someone can register. Tokens are single-use and expire in 7 days.',
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      height: 240,
                      child: invites.isEmpty
                          ? Center(
                              child: Text('No invites yet.',
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                      color:
                                          theme.colorScheme.onSurfaceVariant)),
                            )
                          : ListView.separated(
                              itemCount: invites.length,
                              separatorBuilder: (_, _) =>
                                  const SizedBox(height: 6),
                              itemBuilder: (_, i) {
                                final inv = invites[i];
                                return Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 8),
                                  decoration: BoxDecoration(
                                    color:
                                        theme.colorScheme.surfaceContainerHigh,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: SelectableText(
                                          inv.token,
                                          style: theme.textTheme.bodySmall
                                              ?.copyWith(
                                                  fontFamily: 'monospace'),
                                        ),
                                      ),
                                      Text(
                                        inv.isUsed ? 'Used' : 'Available',
                                        style: theme.textTheme.labelSmall
                                            ?.copyWith(
                                          color: inv.isUsed
                                              ? theme.colorScheme.error
                                              : theme.colorScheme.tertiary,
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: state.closeDialog,
                          child: const Text('Close'),
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
