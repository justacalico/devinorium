part of '../settings_page.dart';

/// Federation card under the Servers topic: satellite machines paired with
/// this hub. A satellite is a stateless runner; projects bound to it run
/// their agents, files, git and terminals on that machine. The card stays
/// hidden on servers without federation routes and for non-owners.
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

  Future<void> _openPairDialog(BuildContext context, AppState state) async {
    await showDialog<void>(
      context: context,
      builder: (context) => _PairNodeDialog(state: state),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = l10n(context);
    final state = context.read<AppState>();

    return Selector<
      AppState,
      ({List<FederationNode> nodes, bool supported, bool isOwner})
    >(
      selector: (_, s) => (
        nodes: s.federationNodes,
        supported: s.federationSupported,
        isOwner: s.isOwner,
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
                  return ListTile(
                    key: Key('node_${node.id}'),
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.dns_outlined),
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
                      onPressed: () => unawaited(_remove(context, state, node)),
                    ),
                  );
                },
              ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonalIcon(
                key: const Key('node_pair_button'),
                icon: const Icon(Icons.link),
                label: Text(l.pairNode),
                onPressed: () => unawaited(_openPairDialog(context, state)),
              ),
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

/// The pairing dialog: satellite URL plus the code it printed at startup.
class _PairNodeDialog extends StatefulWidget {
  const _PairNodeDialog({required this.state});

  final AppState state;

  @override
  State<_PairNodeDialog> createState() => _PairNodeDialogState();
}

class _PairNodeDialogState extends State<_PairNodeDialog> {
  final _urlController = TextEditingController();
  final _codeController = TextEditingController();
  final _nameController = TextEditingController();
  var _submitting = false;
  String? _error;

  @override
  void dispose() {
    _urlController.dispose();
    _codeController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    var url = _urlController.text.trim();
    // Bare host:port inputs get the scheme the backend expects.
    if (url.isNotEmpty && !url.contains('://')) {
      url = 'http://$url';
    }
    final code = _codeController.text.trim();
    final l = l10n(context);
    if (url.isEmpty || code.isEmpty) {
      setState(() => _error = l.nodePairFieldsRequired);
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    final error = await widget.state.pairFederationNode(
      url: url,
      code: code,
      name: _nameController.text.trim().isEmpty
          ? null
          : _nameController.text.trim(),
    );
    if (!mounted) return;
    if (error == null) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _submitting = false;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = l10n(context);
    final theme = Theme.of(context);
    final canSubmit =
        _urlController.text.trim().isNotEmpty &&
        _codeController.text.trim().isNotEmpty &&
        !_submitting;
    return AlertDialog(
      title: Text(l.pairNodeTitle),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l.pairNodeHint,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('pair_url'),
              controller: _urlController,
              enabled: !_submitting,
              decoration: InputDecoration(
                labelText: l.nodeUrl,
                hintText: 'http://machine:7878',
                border: const OutlineInputBorder(),
              ),
              keyboardType: TextInputType.url,
              autocorrect: false,
              onChanged: (_) => setState(() => _error = null),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('pair_code'),
              controller: _codeController,
              enabled: !_submitting,
              decoration: InputDecoration(
                labelText: l.pairingCode,
                hintText: 'XXXX-XXXX-XXXX-XXXX',
                border: const OutlineInputBorder(),
              ),
              autocorrect: false,
              onChanged: (_) => setState(() => _error = null),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('pair_name'),
              controller: _nameController,
              enabled: !_submitting,
              decoration: InputDecoration(
                labelText: l.nodeNameOptional,
                border: const OutlineInputBorder(),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l.cancel),
        ),
        FilledButton(
          key: const Key('pair_submit'),
          onPressed: canSubmit ? _submit : null,
          child: _submitting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(l.pair),
        ),
      ],
    );
  }
}
