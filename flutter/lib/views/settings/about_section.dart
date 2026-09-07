part of '../settings_page.dart';

const _license = 'AGPL-3.0-only';

class _AboutLinks {
  static const repository = 'https://gitlab.com/HttpAnimations/devinorium';
  static const privacyPolicy =
      'https://gitlab.com/HttpAnimations/devinorium/-/blob/main/privacy_policy.md';
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
      final update = await widget.state.checkForAppUpdate();
      if (!mounted) return;
      if (update == null || !update.updateAvailable) {
        final l = l10n(context);
        final messenger = ScaffoldMessenger.of(context);
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              update == null ? l.aboutUpdateCheckFailed : l.aboutUpToDate,
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _checkingUpdate = false);
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
                final String title;
                if (snapshot.connectionState == ConnectionState.waiting) {
                  title = l.loading;
                } else if (snapshot.hasError) {
                  title = l.error;
                } else {
                  final version = snapshot.data?.version ?? '';
                  title = version.isEmpty ? l.noValue : version;
                }
                // Only link to the release once the installed version has
                // been resolved.
                final update =
                    snapshot.hasData &&
                        appUpdate != null &&
                        appUpdate.updateAvailable
                    ? appUpdate
                    : null;
                return _AboutVersionTile(title: title, appUpdate: update);
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
          icon: Icons.privacy_tip,
          label: l.aboutPrivacyPolicy,
          url: _AboutLinks.privacyPolicy,
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

class _AboutVersionTile extends StatefulWidget {
  final String title;
  final AppUpdate? appUpdate;

  const _AboutVersionTile({required this.title, this.appUpdate});

  @override
  State<_AboutVersionTile> createState() => _AboutVersionTileState();
}

class _AboutVersionTileState extends State<_AboutVersionTile> {
  bool _opening = false;

  Future<void> _open() async {
    final update = widget.appUpdate;
    if (_opening || update == null) return;
    setState(() => _opening = true);
    try {
      await openLink(update.releaseUrl);
    } catch (e) {
      if (!mounted) return;
      final l = l10n(context);
      final messenger = ScaffoldMessenger.of(context);
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(content: Text(l.aboutOpenLinkFailed(update.releaseUrl))),
      );
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final l = l10n(context);
    final update = widget.appUpdate;

    Widget? trailing;
    if (_opening) {
      trailing = ExcludeSemantics(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: colors.onSurfaceVariant,
          ),
        ),
      );
    } else if (update != null) {
      trailing = Chip(
        label: Text(l.appUpdateAvailable(update.latestVersion)),
        visualDensity: VisualDensity.compact,
      );
    }

    return _AboutTile(
      icon: Icons.tag,
      title: widget.title,
      subtitle: l.aboutVersion,
      trailing: trailing,
      onTap: update == null || _opening ? null : () => unawaited(_open()),
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
