part of '../sidebar.dart';

class _NodeSwitcher extends StatelessWidget {
  const _NodeSwitcher();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = l10n(context);
    final state = context.read<AppState>();

    return Selector<
      AppState,
      ({
        List<FederationNode> nodes,
        String? activeNodeId,
        String selfName,
        bool supported,
      })
    >(
      selector: (_, s) => (
        nodes: s.federationNodes,
        activeNodeId: s.activeNodeId,
        selfName: s.federationSelfName,
        supported: s.federationSupported,
      ),
      builder: (context, model, _) {
        // Nothing to pick until the hub reports at least one satellite.
        if (!model.supported || model.nodes.isEmpty) {
          return const SizedBox.shrink();
        }

        final activeId = model.activeNodeId;
        final active = activeId == null
            ? null
            : model.nodes.where((n) => n.id == activeId).firstOrNull;

        Widget statusDot(FederationNode? node) {
          final online = node == null || node.online;
          return Icon(
            Icons.circle,
            size: 8,
            color: online
                ? theme.colorScheme.primary
                : theme.colorScheme.error,
          );
        }

        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: MenuAnchor(
            menuChildren: [
              MenuItemButton(
                leadingIcon: activeId == null
                    ? Icon(
                        Icons.check,
                        size: 18,
                        color: theme.colorScheme.primary,
                      )
                    : const SizedBox(width: 18, height: 18),
                onPressed: activeId == null
                    ? null
                    : () => unawaited(state.switchNode(null)),
                child: Text(
                  model.selfName.isNotEmpty ? model.selfName : l.thisHub,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  softWrap: false,
                ),
              ),
              const Divider(height: 1),
              for (final node in model.nodes)
                MenuItemButton(
                  leadingIcon: node.id == activeId
                      ? Icon(
                          Icons.check,
                          size: 18,
                          color: theme.colorScheme.primary,
                        )
                      : const SizedBox(width: 18, height: 18),
                  trailingIcon: statusDot(node),
                  onPressed: node.id == activeId
                      ? null
                      : () => unawaited(state.switchNode(node.id)),
                  child: Text(
                    node.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    softWrap: false,
                  ),
                ),
            ],
            builder: (context, controller, child) {
              return Tooltip(
                message: l.switchNode,
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
                        active == null
                            ? Icons.hub_outlined
                            : Icons.dns_outlined,
                        size: 18,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          active?.name ??
                              (model.selfName.isNotEmpty
                                  ? model.selfName
                                  : l.thisHub),
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w500,
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                      ),
                      statusDot(active),
                      const SizedBox(width: 6),
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
