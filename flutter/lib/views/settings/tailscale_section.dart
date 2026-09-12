part of '../settings_page.dart';

/// Tailscale card under the Servers topic. Shows the tailnet identity and
/// advertised endpoints of the active server plus the `tailscale serve`
/// toggle. The bundled desktop profile renders it greyed out: that server
/// binds to loopback and must not be republished onto a tailnet.
class _TailscaleSection extends StatelessWidget {
  const _TailscaleSection();

  Future<void> _setServe(
    BuildContext context,
    AppState state,
    bool enabled,
  ) async {
    final error = await state.setTailscaleServe(enabled);
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
      ({TailscaleInfo? info, bool busy, bool isOwner, bool isLocal})
    >(
      selector: (_, s) => (
        info: s.tailscaleInfo,
        busy: s.tailscaleBusy,
        isOwner: s.isOwner,
        isLocal: s.multiServerState.activeProfile?.isLocal ?? false,
      ),
      builder: (context, model, _) {
        final info = model.info;
        final bundled = model.isLocal || (info?.localMode ?? false);
        // Hidden until the server answers, except on the bundled profile
        // where the greyed-out card explains why the feature is missing.
        if (info == null && !bundled) return const SizedBox.shrink();
        final ts = bundled ? null : info;

        final canToggle =
            ts != null &&
            ts.installed &&
            ts.magicDnsName != null &&
            model.isOwner &&
            !model.busy;

        final String desc;
        if (bundled) {
          desc = l.tailscaleBundledHint;
        } else if (ts == null || !ts.installed) {
          desc = l.tailscaleNotInstalled;
        } else if (ts.tailnetIpv4.isEmpty && ts.magicDnsName == null) {
          desc = l.tailscaleNotConnected;
        } else {
          desc = l.tailscaleDescription;
        }

        return _SectionCard(
          title: 'Tailscale',
          children: [
            Text(
              desc,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (ts != null && ts.endpoints.isNotEmpty) ...[
              const SizedBox(height: 12),
              for (final ep in ts.endpoints)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              ep.label,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                            SelectableText(
                              ep.url,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontFamily: 'monospace',
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (!ep.reachable)
                        Text(
                          l.tailscaleUnreachable,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.error,
                          ),
                        ),
                    ],
                  ),
                ),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l.tailscaleHttps,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      Text(
                        l.tailscaleHttpsHint,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (model.busy)
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  Switch(
                    key: const Key('tailscale_serve_switch'),
                    value: ts?.serveEnabled ?? false,
                    onChanged: canToggle
                        ? (v) => unawaited(_setServe(context, state, v))
                        : null,
                  ),
              ],
            ),
            if (ts != null && ts.installed && !model.isOwner)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  l.tailscaleOnlyOwner,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
