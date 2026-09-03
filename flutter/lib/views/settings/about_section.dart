part of '../settings_page.dart';

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
    _packageInfo = PackageInfo.fromPlatform();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = l10n(context);

    return _SectionCard(
      title: l.about,
      children: [
        _SettingsRow(
          label: l.name,
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
                value: '—',
              );
            }
            final version = snapshot.data?.version ?? '';
            return _SettingsRow(
              label: l.aboutVersion,
              value: version.isEmpty ? '—' : version,
            );
          },
        ),
        const Divider(),
        Text(
          l.aboutDescription,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 16),
        _SettingsRow(
          label: l.aboutLicense,
          value: l.aboutLicenseText,
        ),
        const Divider(),
        _AboutLink(
          label: l.aboutSourceCode,
          url: _AboutLinks.repository,
          onOpen: widget.state.openLink,
        ),
        const Divider(),
        _AboutLink(
          label: l.aboutSupport,
          url: _AboutLinks.support,
          onOpen: widget.state.openLink,
        ),
      ],
    );
  }
}

class _AboutLink extends StatelessWidget {
  final String label;
  final String url;
  final Future<void> Function(String) onOpen;

  const _AboutLink({
    required this.label,
    required this.url,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = l10n(context);

    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Text(label),
      subtitle: Text(
        url,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.primary,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        softWrap: false,
      ),
      trailing: const Icon(Icons.open_in_new, size: 18),
      onTap: () async {
        try {
          await onOpen(url);
        } catch (e) {
          if (!context.mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('${l.error}: $e')),
          );
        }
      },
    );
  }
}
