part of '../sidebar.dart';

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
        final topics = settingsTopics(model.isOwner, l);
        int indexOf(SettingsTopic t) =>
            topics.indexWhere((e) => e.topic == t);
        final serversIndex = indexOf(SettingsTopic.servers);
        // Personalization, About, and Servers stay usable without a server.
        bool enabled(int i) =>
            model.hasServer ||
            i == indexOf(SettingsTopic.personalization) ||
            i == indexOf(SettingsTopic.about) ||
            i == serversIndex;
        var selectedIndex = model.settingsTopicIndex;
        if (!enabled(selectedIndex)) selectedIndex = serversIndex;

        // The topic list is small and fixed, so a Column builds every tile
        // eagerly; scrolling keeps the last item reachable on short screens.
        return SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
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
                      if (topics[i].topic == SettingsTopic.manage) ...[
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
          ),
        );
      },
    );
  }
}
