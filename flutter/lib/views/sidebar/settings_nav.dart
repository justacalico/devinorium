part of '../sidebar.dart';

List<({IconData icon, String label})> _settingsTopics(
  bool isOwner,
  AppLocalizations l,
) {
  return [
    (icon: Icons.person_outline, label: l.account),
    (icon: Icons.cloud_outlined, label: l.providers),
    (icon: Icons.palette_outlined, label: l.personalization),
    (icon: Icons.code_outlined, label: l.git),
    (icon: Icons.folder_outlined, label: l.cloneRoot),
    if (isOwner)
      (icon: Icons.manage_accounts_outlined, label: l.manage),
    (icon: Icons.info_outlined, label: l.about),
    (icon: Icons.dns_outlined, label: l.servers),
  ];
}

class _SettingsNav extends StatelessWidget {
  const _SettingsNav();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = l10n(context);
    final state = context.read<AppState>();

    return Selector<AppState,
        ({bool isOwner, int settingsTopicIndex, bool hasServer})>(
      selector: (_, s) => (
        isOwner: s.isOwner,
        settingsTopicIndex: s.settingsTopicIndex,
        hasServer: s.multiServerState.hasAnyServer,
      ),
      builder: (context, model, _) {
        final topics = _settingsTopics(model.isOwner, l);
        final serversIndex = topics.length - 1;
        bool enabled(int i) =>
            model.hasServer || i == 2 || i == serversIndex;
        var selectedIndex = model.settingsTopicIndex;
        if (!enabled(selectedIndex)) selectedIndex = serversIndex;

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
                  enabled: enabled(i),
                  selected: i == selectedIndex,
                  selectedTileColor: theme.colorScheme.secondaryContainer,
                  dense: true,
                  onTap: enabled(i)
                      ? () {
                          state.setSettingsTopicIndex(i);
                          Scaffold.of(context).closeDrawer();
                        }
                      : null,
                ),
              ),
          ],
        );
      },
    );
  }
}
