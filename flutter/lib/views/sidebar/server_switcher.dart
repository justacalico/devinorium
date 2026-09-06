part of '../sidebar.dart';

class _ServerSwitcher extends StatelessWidget {
  const _ServerSwitcher();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = l10n(context);
    final state = context.read<AppState>();

    if (kIsWeb) return const SizedBox.shrink();

    return Selector<AppState, ({List<ServerProfile> profiles, String? activeId})>(
      selector: (_, s) => (
        profiles: s.serverProfiles,
        activeId: s.activeServerId,
      ),
      builder: (context, model, _) {
        final profiles = model.profiles;
        if (profiles.length < 2) return const SizedBox.shrink();

        final activeId = model.activeId;
        if (activeId == null) return const SizedBox.shrink();

        final active = profiles.firstWhere(
          (p) => p.id == activeId,
          orElse: () => profiles.first,
        );

        final scaffold = Scaffold.maybeOf(context);

        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: MenuAnchor(
            menuChildren: [
              for (final profile in profiles)
                MenuItemButton(
                  leadingIcon: profile.id == activeId
                      ? Icon(
                          Icons.check,
                          size: 18,
                          color: theme.colorScheme.primary,
                        )
                      : const SizedBox(width: 18, height: 18),
                  onPressed: profile.id == activeId
                      ? null
                      : () => unawaited(state.switchServer(profile.id)),
                  child: Text(profile.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      softWrap: false),
                ),
              const Divider(height: 1),
              MenuItemButton(
                leadingIcon: const Icon(Icons.settings_outlined, size: 18),
                onPressed: () {
                  final topics = _settingsTopics(state.isOwner, l);
                  state.setSettingsTopicIndex(topics.length - 1);
                  state.setPage(MainPage.settings);
                  scaffold?.closeDrawer();
                },
                child: Text(l.manageServers),
              ),
            ],
            builder: (context, controller, child) {
              return Tooltip(
                message: l.switchServer,
                child: TextButton(
                  onPressed: () {
                    if (controller.isOpen) {
                      controller.close();
                    } else {
                      controller.open();
                    }
                  },
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    minimumSize: const Size.fromHeight(36),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    backgroundColor: theme.colorScheme.surfaceContainer,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.cloud_outlined,
                        size: 18,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          active.label,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w500,
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                      ),
                      Icon(
                        Icons.expand_more,
                        size: 18,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }
}
