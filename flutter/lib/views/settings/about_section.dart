part of '../settings_page.dart';

const _license = 'AGPL-3.0-only';

class _AboutLinks {
  static const repository = 'https://gitlab.com/HttpAnimations/devinorium';
  static const support = 'https://gitlab.com/HttpAnimations/devinorium/-/issues';
}

class _AboutSection extends StatefulWidget {
  final AppState state;

  const _AboutSection({required this.state});

  @override
  State<_AboutSection> createState() => _AboutSectionState();
}

class _AboutSectionState extends State<_AboutSection> {
  late final Future<PackageInfo> _packageInfo;

  @override
  void initState() {
    super.initState();
    _packageInfo = widget.state.packageInfo();
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
        const Divider(),
        _SettingsRow(
          label: l.appName,
          value: l.appTitle,
        ),
        const Divider(),
        FutureBuilder<PackageInfo>(
          future: _packageInfo,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return _SettingsRow(
                label: l.aboutVersion,
                value: l.loading,
              );
            }
            if (snapshot.hasError) {
              return _SettingsRow(
                label: l.aboutVersion,
                value: l.error,
              );
            }
            final version = snapshot.data?.version ?? '';
            return _SettingsRow(
              label: l.aboutVersion,
              value: version.isEmpty ? l.noValue : version,
            );
          },
        ),
        const Divider(),
        _SettingsRow(
          label: l.aboutLicense,
          value: _license,
        ),
        const Divider(),
        _AboutLink(
          label: l.aboutSourceCode,
          url: _AboutLinks.repository,
        ),
        const Divider(),
        _AboutLink(
          label: l.aboutSupport,
          url: _AboutLinks.support,
        ),
      ],
    );
  }
}

class _AboutLink extends StatefulWidget {
  final String label;
  final String url;

  const _AboutLink({
    required this.label,
    required this.url,
  });

  @override
  State<_AboutLink> createState() => _AboutLinkState();
}

class _AboutLinkState extends State<_AboutLink> {
  bool _opening = false;

  Future<void> _open() async {
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
    final theme = Theme.of(context);
    final l = l10n(context);

    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Text(widget.label),
      subtitle: Tooltip(
        message: widget.url,
        child: Text(
          widget.url,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.primary,
            decoration: TextDecoration.underline,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          softWrap: false,
        ),
      ),
      trailing: Tooltip(
        message: l.openInBrowser,
        child: Icon(
          Icons.open_in_new,
          size: 18,
          color: _opening ? theme.colorScheme.outline : null,
        ),
      ),
      onTap: _opening ? null : _open,
    );
  }
}
