part of '../settings_page.dart';

const _license = 'AGPL-3.0-only';

class _AboutLinks {
  static const repository = 'https://gitlab.com/HttpAnimations/devinorium';
  static const support =
      'https://gitlab.com/HttpAnimations/devinorium/-/work_items';
  static const releases = VersionChecker.releasesUrl;
}

class _AboutSection extends StatefulWidget {
  final AppState state;

  const _AboutSection({required this.state});

  @override
  State<_AboutSection> createState() => _AboutSectionState();
}

class _AboutSectionState extends State<_AboutSection> {
  late Future<PackageInfo> _packageInfo;
  bool _openingUpdate = false;
  bool _checkingUpdate = false;

  @override
  void initState() {
    super.initState();
    _packageInfo = widget.state.packageInfo();
  }

  @override
  void didUpdateWidget(covariant _AboutSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      _packageInfo = widget.state.packageInfo();
    }
  }

  Future<void> _checkForUpdates() async {
    if (_checkingUpdate) return;
    setState(() => _checkingUpdate = true);
    try {
      await widget.state.checkForAppUpdate();
      if (!mounted) return;
      final update = widget.state.appUpdate;
      if (update != null && !update.updateAvailable) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l10n(context).aboutUpToDate)));
      }
    } finally {
      if (mounted) setState(() => _checkingUpdate = false);
    }
  }

  Future<void> _openRelease(String url) async {
    if (_openingUpdate) return;
    setState(() => _openingUpdate = true);
    try {
      await openLink(url);
    } catch (e) {
      if (!mounted) return;
      final l = l10n(context);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.aboutOpenLinkFailed(url))));
    } finally {
      if (mounted) setState(() => _openingUpdate = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = l10n(context);

    return _SectionCard(
      title: l.about,
      children: [
        Text(
          l.aboutDescription,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 16),
        _AboutTile(icon: Icons.apps, title: l.appTitle, subtitle: l.appName),
        Selector<AppState, AppUpdate?>(
          selector: (_, state) => state.appUpdate,
          builder: (context, appUpdate, _) {
            return FutureBuilder<PackageInfo>(
              future: _packageInfo,
              builder: (context, snapshot) {
                Widget? trailing;
                VoidCallback? onTap;
                if (appUpdate != null && appUpdate.updateAvailable) {
                  trailing = Chip(
                    label: Text(l.appUpdateAvailable(appUpdate.latestVersion)),
                    visualDensity: VisualDensity.compact,
                  );
                  onTap = _openingUpdate
                      ? null
                      : () => unawaited(_openRelease(appUpdate.releaseUrl));
                }

                if (snapshot.connectionState == ConnectionState.waiting) {
                  return _AboutTile(
                    icon: Icons.tag,
                    title: l.loading,
                    subtitle: l.aboutVersion,
                    trailing: trailing,
                    onTap: onTap,
                  );
                }
                if (snapshot.hasError) {
                  return _AboutTile(
                    icon: Icons.tag,
                    title: l.error,
                    subtitle: l.aboutVersion,
                    trailing: trailing,
                    onTap: onTap,
                  );
                }
                final version = snapshot.data?.version ?? '';
                return _AboutTile(
                  icon: Icons.tag,
                  title: version.isEmpty ? l.noValue : version,
                  subtitle: l.aboutVersion,
                  trailing: trailing,
                  onTap: onTap,
                );
              },
            );
          },
        ),
        _AboutTile(
          icon: Icons.update,
          title: l.aboutCheckForUpdates,
          subtitle: l.aboutCheckForUpdatesSubtitle,
          trailing: ExcludeSemantics(
            child: _checkingUpdate
                ? SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  )
                : Icon(
                    Icons.refresh,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
          ),
          onTap: _checkingUpdate ? null : () => unawaited(_checkForUpdates()),
        ),
        _AboutTile(
          icon: Icons.gavel,
          title: _license,
          subtitle: l.aboutLicense,
        ),
        const Divider(),
        _AboutLinkTile(
          icon: Icons.code,
          label: l.aboutSourceCode,
          url: _AboutLinks.repository,
        ),
        _AboutLinkTile(
          icon: Icons.support,
          label: l.aboutSupport,
          url: _AboutLinks.support,
        ),
        _AboutLinkTile(
          icon: Icons.new_releases_outlined,
          label: l.aboutReleases,
          url: _AboutLinks.releases,
        ),
      ],
    );
  }
}

class _AboutTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final String? tooltip;
  final Widget? trailing;
  final VoidCallback? onTap;

  const _AboutTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.tooltip,
    this.trailing,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    Widget subtitleWidget = Text(
      subtitle,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    if (tooltip != null) {
      subtitleWidget = Tooltip(message: tooltip, child: subtitleWidget);
    }

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: ExcludeSemantics(
        child: Icon(icon, size: 22, color: colors.onSurfaceVariant),
      ),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: subtitleWidget,
      trailing: trailing,
      onTap: onTap,
    );
  }
}

class _AboutLinkTile extends StatefulWidget {
  final IconData icon;
  final String label;
  final String url;

  const _AboutLinkTile({
    required this.icon,
    required this.label,
    required this.url,
  });

  @override
  State<_AboutLinkTile> createState() => _AboutLinkTileState();
}

class _AboutLinkTileState extends State<_AboutLinkTile> {
  bool _opening = false;

  Future<void> _open() async {
    if (_opening) return;
    setState(() => _opening = true);
    try {
      await openLink(widget.url);
    } catch (e) {
      if (!mounted) return;
      final l = l10n(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l.aboutOpenLinkFailed(widget.url))),
      );
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    final trailing = _opening
        ? SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: colors.onSurfaceVariant,
            ),
          )
        : Icon(Icons.open_in_new, size: 18, color: colors.onSurfaceVariant);

    return _AboutTile(
      icon: widget.icon,
      title: widget.label,
      subtitle: widget.url,
      tooltip: widget.url,
      trailing: ExcludeSemantics(child: trailing),
      onTap: _opening ? null : _open,
    );
  }
}
