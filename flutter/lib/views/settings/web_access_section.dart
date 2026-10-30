part of '../settings_page.dart';

/// Web access card: whether agent runs get the builtin server-side browser
/// MCP server. Owner-only like the MCP server list: the browser runs on
/// the machine that executes the agent (hub or satellite), with that
/// server's network reach, so it works with no client connected.
class _WebAccessSection extends StatelessWidget {
  const _WebAccessSection();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = l10n(context);
    final state = context.read<AppState>();

    return Selector<AppState, ({bool enabled, bool isOwner})>(
      selector: (_, s) => (enabled: s.webAccessEnabled, isOwner: s.isOwner),
      builder: (context, model, _) {
        if (!model.isOwner) {
          return const SizedBox.shrink();
        }
        return _SectionCard(
          title: l.webAccess,
          children: [
            Text(
              l.webAccessDescription,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              key: const Key('web_access_enabled'),
              title: Text(l.webAccessToggle),
              value: model.enabled,
              onChanged: (v) async {
                final error = await state.saveWebAccess(v);
                if (error != null) {
                  state.setGlobalError(error);
                }
              },
            ),
          ],
        );
      },
    );
  }
}
