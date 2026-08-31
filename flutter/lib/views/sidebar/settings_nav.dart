part of '../sidebar.dart';

class _SettingsNav extends StatelessWidget {
  const _SettingsNav();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final l = l10n(context);
    final topics = [
      (icon: Icons.person_outline, label: l.account),
      (icon: Icons.cloud_outlined, label: l.providers),
      (icon: Icons.palette_outlined, label: l.personalization),
      (icon: Icons.code_outlined, label: l.git),
      if (state.isOwner)
        (icon: Icons.manage_accounts_outlined, label: l.manage),
    ];

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      children: [
        _SectionHeader(l.topics),
        for (var i = 0; i < topics.length; i++)
          Material(
            color: Colors.transparent,
            elevation: 0,
            shape: const StadiumBorder(),
            clipBehavior: Clip.antiAlias,
            child: ListTile(
              leading: Icon(topics[i].icon, size: 20),
              title: Row(
                children: [
                  Text(topics[i].label),
                  if (topics[i].label == l.manage) ...[
                    const SizedBox(width: 6),
                    const OwnerBadge(),
                  ],
                ],
              ),
              selected: i == state.settingsTopicIndex,
              selectedTileColor: theme.colorScheme.secondaryContainer,
              dense: true,
              onTap: () {
                state.setSettingsTopicIndex(i);
                Scaffold.of(context).closeDrawer();
              },
            ),
          ),
      ],
    );
  }
}
