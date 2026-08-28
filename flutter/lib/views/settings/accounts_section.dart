part of '../settings_page.dart';

class _AccountsSection extends StatefulWidget {
  final AppState state;

  const _AccountsSection({required this.state});

  @override
  State<_AccountsSection> createState() => _AccountsSectionState();
}

class _AccountsSectionState extends State<_AccountsSection> {
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
