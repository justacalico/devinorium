part of '../settings_page.dart';

/// Federation card under the Servers topic: the satellite nodes registered
/// with the active hub. Satellites announce themselves, so there is no add
/// button — the owner can only inspect and deregister entries. The card
/// stays hidden on servers without federation routes (they 404 the list).
class _NodesSection extends StatelessWidget {
  const _NodesSection();

  Future<void> _remove(
    BuildContext context,
    AppState state,
    FederationNode node,
  ) async {
    final l = l10n(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(l.removeNodeConfirm(node.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l.delete),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final error = await state.removeFederationNode(node.id);
    if (error != null && context.mounted) {
      state.setGlobalError(error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = l10n(context);
    final state = context.read<AppState>();

    return Selector<
      AppState,
      ({
        List<FederationNode> nodes,
        bool supported,
        bool isOwner,
        String? activeNodeId,
      })
    >(
      selector: (_, s) => (
        nodes: s.federationNodes,
        supported: s.federationSupported,
        isOwner: s.isOwner,
        activeNodeId: s.activeNodeId,
      ),
      builder: (context, model, _) {
        if (!model.supported || !model.isOwner) {
          return const SizedBox.shrink();
        }

        return _SectionCard(
          title: l.federationNodes,
          children: [
            Text(
              l.federationNodesHint,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            if (model.nodes.isEmpty)
              Text(l.noNodesRegistered, style: theme.textTheme.bodyMedium)
            else
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: model.nodes.length,
                separatorBuilder: (context, index) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final node = model.nodes[index];
                  final isActive = node.id == model.activeNodeId;
                  return ListTile(
                    key: Key('node_${node.id}'),
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      isActive ? Icons.check_circle : Icons.dns_outlined,
                      color: isActive ? theme.colorScheme.primary : null,
                    ),
                    title: Row(
                      children: [
                        Flexible(
                          child: Text(
                            node.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          node.online ? l.nodeOnline : l.nodeOffline,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: node.online
                                ? SemanticColors.of(context).success
                                : theme.colorScheme.error,
                          ),
                        ),
                      ],
                    ),
                    subtitle: Tooltip(
                      message: node.baseUrl,
                      child: Text(
                        [
                          node.baseUrl,
                          if (node.version.isNotEmpty) 'v${node.version}',
                          if (!node.online && node.lastSeenAt.isNotEmpty)
                            _lastSeen(node.lastSeenAt, l),
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        softWrap: false,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                    trailing: IconButton(
                      key: Key('node_remove_${node.id}'),
                      icon: const Icon(Icons.delete_outline),
                      tooltip: l.removeNode,
                      onPressed: () =>
                          unawaited(_remove(context, state, node)),
                    ),
                  );
                },
              ),
          ],
        );
      },
    );
  }

  String _lastSeen(String rfc3339, AppLocalizations l) {
    final t = DateTime.tryParse(rfc3339);
    if (t == null) return '';
    return timeAgo(t.toLocal(), l);
  }
}
