part of '../settings_page.dart';

class _PersonalizationSection extends StatelessWidget {
  final AppState state;

  const _PersonalizationSection({required this.state});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = l10n(context);
    return _SectionCard(
      title: l.personalization,
      children: [
        Row(
          children: [
            Text(
              l.theme,
              style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: SegmentedButton<ThemeMode>(
                segments: [
                  ButtonSegment(
                    value: ThemeMode.light,
                    label: Text(l.light),
                  ),
                  ButtonSegment(
                    value: ThemeMode.dark,
                    label: Text(l.dark),
                  ),
                  ButtonSegment(
                    value: ThemeMode.system,
                    label: Text(l.system),
                  ),
                ],
                selected: {state.themeMode},
                onSelectionChanged: (modes) {
                  if (modes.isNotEmpty) state.setThemeMode(modes.first);
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        Row(
          children: [
            Text(
              l.language,
              style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: DropdownButton<String>(
                value: state.locale.languageCode,
                isExpanded: true,
                underline: const SizedBox.shrink(),
                items: [
                  DropdownMenuItem(value: 'en', child: Text(l.languageEnglish)),
                ],
                onChanged: (value) {
                  if (value != null) state.setLanguage(value);
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        Text(
          l.notifications,
          style: theme.textTheme.titleSmall,
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          title: Text(l.completionNotifications),
          subtitle: Text(l.completionNotificationsDescription),
          value: state.notificationsEnabled,
          onChanged: (v) => state.setNotificationsEnabled(v),
        ),
      ],
    );
  }
}
