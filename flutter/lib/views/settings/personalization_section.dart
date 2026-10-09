part of '../settings_page.dart';

class _PersonalizationSection extends StatelessWidget {
  final AppState state;

  const _PersonalizationSection({required this.state});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = l10n(context);
    final themeProvider = context.watch<ThemeProvider>();
    final choice = themeProvider.choice;

    return _SectionCard(
      title: l.personalization,
      children: [
        Row(
          children: [
            Text(
              l.theme,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: _ThemeSelector(
                choice: choice,
                onSelected: (value) =>
                    _onThemeSelected(context, value, themeProvider),
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
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: DropdownButton<String>(
                value: state.language,
                isExpanded: true,
                underline: const SizedBox.shrink(),
                items: [
                  DropdownMenuItem(value: 'system', child: Text(l.system)),
                  DropdownMenuItem(value: 'en', child: Text(l.languageEnglish)),
                  DropdownMenuItem(
                    value: 'zh',
                    child: Text(l.languageSimplifiedChinese),
                  ),
                ],
                onChanged: (value) {
                  if (value != null) state.setLanguage(value);
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l.defaultPermissionLevel,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    l.defaultPermissionLevelHint,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 16),
            Selector<AppState, String>(
              selector: (_, s) => s.defaultPermission,
              builder: (context, permission, _) =>
                  _DefaultPermissionDropdown(value: permission, state: state),
            ),
          ],
        ),
        const SizedBox(height: 24),
        Text(l.notifications, style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        SwitchListTile(
          title: Text(l.completionNotifications),
          subtitle: Text(l.completionNotificationsDescription),
          value: state.notificationsEnabled,
          onChanged: (v) => state.setNotificationsEnabled(v),
        ),
        _NotificationPermissionHint(state: state),
        if (state.multiWindowSupported)
          SwitchListTile(
            title: Text(l.multipleWindows),
            subtitle: Text(l.multipleWindowsDescription),
            value: state.multiWindowEnabled,
            onChanged: (v) => state.setMultiWindowEnabled(v),
          ),
        if (state.pushSupported)
          _PushTile(state: state)
        else if (!kIsWeb)
          const SizedBox.shrink()
        else
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              l.pushNotificationsUnsupported,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _onThemeSelected(
    BuildContext context,
    _ThemeMenuItem? item,
    ThemeProvider themeProvider,
  ) async {
    if (item == null) return;
    switch (item) {
      case _ThemeMenuItem.system:
        await themeProvider.selectSystem();
      case _ThemeMenuItem.light:
        await themeProvider.selectBuiltIn(BuiltInThemes.lightId);
      case _ThemeMenuItem.dark:
        await themeProvider.selectBuiltIn(BuiltInThemes.darkId);
      case _ThemeMenuItem.oled:
        await themeProvider.selectBuiltIn(BuiltInThemes.oledId);
    }
  }
}

class _DefaultPermissionDropdown extends StatelessWidget {
  final String value;
  final AppState state;

  const _DefaultPermissionDropdown({required this.value, required this.state});

  @override
  Widget build(BuildContext context) {
    final l = l10n(context);
    final modes = permissionModeLabels(l);
    final items = [
      for (final (id, label) in modes)
        DropdownMenuItem<String>(value: id, child: Text(label)),
      if (!modes.any((m) => m.$1 == value))
        DropdownMenuItem<String>(value: value, child: Text(value)),
    ];

    return DropdownButton<String>(
      value: value,
      underline: const SizedBox.shrink(),
      items: items,
      onChanged: (v) {
        if (v != null) state.setDefaultPermission(v);
      },
    );
  }
}

/// Warning line under the notifications switch when the platform has the
/// permission hard-denied — the toggle alone cannot turn them back on.
class _NotificationPermissionHint extends StatelessWidget {
  final AppState state;

  const _NotificationPermissionHint({required this.state});

  @override
  Widget build(BuildContext context) {
    final l = l10n(context);
    final theme = Theme.of(context);
    return FutureBuilder<String>(
      future: state.notificationPermissionState(),
      builder: (context, snapshot) {
        if (snapshot.data != 'denied') return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Row(
            children: [
              Icon(
                Icons.notifications_off_outlined,
                size: 16,
                color: theme.colorScheme.error,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l.notificationPermissionDenied,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// The background-push row: subscription switch, live status, and a test
/// button once the server accepts the endpoint.
class _PushTile extends StatefulWidget {
  final AppState state;

  const _PushTile({required this.state});

  @override
  State<_PushTile> createState() => _PushTileState();
}

class _PushTileState extends State<_PushTile> {
  bool _busy = false;

  Future<void> _test() async {
    setState(() => _busy = true);
    try {
      final sent = await widget.state.sendTestPushNotification();
      if (!mounted) return;
      final l = l10n(context);
      showAppMessage(
        context,
        sent > 0 ? l.testNotificationSent : l.testNotificationFailed,
        kind: sent > 0 ? MessageKind.info : MessageKind.error,
      );
    } catch (_) {
      if (!mounted) return;
      showAppMessage(
        context,
        l10n(context).testNotificationFailed,
        kind: MessageKind.error,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = l10n(context);
    final state = widget.state;
    final status = state.pushStatus;
    final subtitle = switch (status) {
      'denied' => l.notificationPermissionDenied,
      'unsupported' || 'unavailable' => l.pushNotificationsUnsupported,
      _ => l.pushNotificationsDescription,
    };
    return Column(
      children: [
        SwitchListTile(
          title: Text(l.pushNotifications),
          subtitle: Text(subtitle),
          value: state.pushEnabled && status == 'on',
          onChanged: _busy
              ? null
              : (v) async {
                  setState(() => _busy = true);
                  try {
                    await state.setPushEnabled(v);
                  } finally {
                    if (mounted) setState(() => _busy = false);
                  }
                },
        ),
        if (status == 'on')
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(right: 16),
              child: TextButton(
                onPressed: _busy ? null : _test,
                child: Text(l.sendTestNotification),
              ),
            ),
          ),
      ],
    );
  }
}

enum _ThemeMenuItem { system, light, dark, oled }

class _ThemeSelector extends StatelessWidget {
  final ThemeChoice choice;
  final ValueChanged<_ThemeMenuItem?> onSelected;

  const _ThemeSelector({required this.choice, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    final l = l10n(context);
    final value = switch (choice) {
      SystemThemeChoice() => _ThemeMenuItem.system,
      BuiltInThemeChoice(:final id) when id == BuiltInThemes.lightId =>
        _ThemeMenuItem.light,
      BuiltInThemeChoice(:final id) when id == BuiltInThemes.darkId =>
        _ThemeMenuItem.dark,
      BuiltInThemeChoice(:final id) when id == BuiltInThemes.oledId =>
        _ThemeMenuItem.oled,
      BuiltInThemeChoice() => null,
    };

    return DropdownButton<_ThemeMenuItem?>(
      value: value,
      isExpanded: true,
      underline: const SizedBox.shrink(),
      items: [
        DropdownMenuItem(value: _ThemeMenuItem.system, child: Text(l.system)),
        DropdownMenuItem(value: _ThemeMenuItem.light, child: Text(l.light)),
        DropdownMenuItem(value: _ThemeMenuItem.dark, child: Text(l.dark)),
        DropdownMenuItem(value: _ThemeMenuItem.oled, child: Text(l.oledTheme)),
      ],
      onChanged: onSelected,
    );
  }
}
