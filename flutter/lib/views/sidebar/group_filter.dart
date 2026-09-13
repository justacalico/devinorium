part of '../sidebar.dart';

/// Dropdown that filters the sidebar project list by group.
/// A null selection means "All" — every project is shown.
class _GroupFilter extends StatelessWidget {
  const _GroupFilter();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = l10n(context);
    final state = context.read<AppState>();

    return Selector<AppState, ({List<ProjectGroup> groups, int? selectedId, bool unsupported})>(
      selector: (_, s) => (
        groups: s.projectGroups,
        selectedId: s.selectedProjectGroupId,
        unsupported: s.projectGroupsUnsupported,
      ),
      builder: (context, model, _) {
        // Backends that predate project groups get the old sidebar layout.
        if (model.unsupported) {
          return const SizedBox.shrink();
        }
        final selectedName = model.groups
            .where((g) => g.id == model.selectedId)
            .map((g) => g.name)
            .firstOrNull;
        final label = selectedName ?? l.groupFilterAll;

        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: MenuAnchor(
            menuChildren: [
              MenuItemButton(
                key: const Key('group_filter_all'),
                trailingIcon: model.selectedId == null
                    ? const Icon(Icons.check, size: 18)
                    : null,
                onPressed: () => state.selectProjectGroup(null),
                child: Text(l.groupFilterAll),
              ),
              for (final g in model.groups)
                MenuItemButton(
                  key: Key('group_filter_${g.id}'),
                  trailingIcon: model.selectedId == g.id
                      ? const Icon(Icons.check, size: 18)
                      : null,
                  onPressed: () => state.selectProjectGroup(g.id),
                  child: Text(
                    g.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              if (model.groups.isNotEmpty) const Divider(height: 1),
              MenuItemButton(
                key: const Key('group_filter_new'),
                leadingIcon: const Icon(Icons.add, size: 18),
                onPressed: () => state.openNewProjectGroupDialog(),
                child: Text(l.newGroup),
              ),
              if (model.groups.isNotEmpty)
                MenuItemButton(
                  key: const Key('group_filter_manage'),
                  leadingIcon: const Icon(Icons.tune, size: 18),
                  onPressed: () => state.openManageProjectGroupsDialog(),
                  child: Text(l.manageGroups),
                ),
            ],
            builder: (context, controller, child) {
              return Material(
                color: theme.colorScheme.surfaceContainer,
                borderRadius: BorderRadius.circular(8),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  key: const Key('group_filter'),
                  onTap: () {
                    if (controller.isOpen) {
                      controller.close();
                    } else {
                      controller.open();
                    }
                  },
                  child: SizedBox(
                    height: 36,
                    child: Row(
                      children: [
                        const SizedBox(width: 10),
                        Icon(
                          Icons.folder_outlined,
                          size: 18,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium,
                          ),
                        ),
                        Icon(
                          Icons.arrow_drop_down,
                          size: 18,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 8),
                      ],
                    ),
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
