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
                customThemeName: themeProvider.activeTheme.name,
                onSelected: (value) =>
                    _onThemeSelected(context, value, themeProvider),
              ),
            ),
            const SizedBox(width: 8),
            TextButton.icon(
              onPressed: () => _showCustomThemeDialog(context, themeProvider),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              icon: const Icon(Icons.upload_file, size: 18),
              label: Text(
                l.themeImport,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        if (choice is CustomThemeChoice &&
            themeProvider.hasValidCustomTheme) ...[
          const SizedBox(height: 16),
          _CustomThemeInfo(theme: themeProvider.activeTheme),
        ],
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
        Text(l.notifications, style: theme.textTheme.titleSmall),
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

  Future<void> _showCustomThemeDialog(
    BuildContext context,
    ThemeProvider themeProvider,
  ) async {
    final css = await showDialog<String>(
      context: context,
      builder: (context) => const _CustomThemeDialog(),
    );
    if (css == null || css.isEmpty) return;
    try {
      await themeProvider.loadCustom(css);
    } on ThemeParseException catch (e) {
      if (!context.mounted) return;
      showAppMessage(
        context,
        '${l10n(context).themeImportError}: $e',
        kind: MessageKind.error,
      );
    }
  }
}

enum _ThemeMenuItem { system, light, dark, oled }

class _ThemeSelector extends StatelessWidget {
  final ThemeChoice choice;
  final String? customThemeName;
  final ValueChanged<_ThemeMenuItem?> onSelected;

  const _ThemeSelector({
    required this.choice,
    required this.customThemeName,
    required this.onSelected,
  });

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
      _ => null,
    };

    // A custom choice (valid or not) has no matching dropdown item, so the
    // hint keeps the selector from going blank and tells the user they are
    // in custom mode. An invalid persisted custom theme still shows "Custom"
    // so they can re-import or pick a built-in from the dropdown.
    final isCustom = choice is CustomThemeChoice;
    final customLabel = isCustom
        ? (customThemeName != null && customThemeName!.isNotEmpty
              ? '${l.themeCustom}: $customThemeName'
              : l.themeCustom)
        : null;

    return DropdownButton<_ThemeMenuItem?>(
      value: value,
      isExpanded: true,
      underline: const SizedBox.shrink(),
      hint: customLabel != null
          ? Text(
              customLabel,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
            )
          : null,
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

class _CustomThemeInfo extends StatelessWidget {
  final ColorTheme theme;

  const _CustomThemeInfo({required this.theme});

  @override
  Widget build(BuildContext context) {
    final l = l10n(context);
    final textTheme = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l.themeCustom, style: textTheme.titleSmall),
        if (theme.name != null) ...[
          const SizedBox(height: 8),
          Text(theme.name!, style: textTheme.bodyMedium),
        ],
        if (theme.metadata.creator.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            '${l.themeCreator}: ${theme.metadata.creator}',
            style: textTheme.bodySmall?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
        ],
        if (theme.metadata.version.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            '${l.themeVersion}: ${theme.metadata.version}',
            style: textTheme.bodySmall?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
        ],
        if (theme.metadata.description.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            '${l.themeDescription}: ${theme.metadata.description}',
            style: textTheme.bodySmall?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}

class _CustomThemeDialog extends StatefulWidget {
  const _CustomThemeDialog();

  @override
  State<_CustomThemeDialog> createState() => _CustomThemeDialogState();
}

class _CustomThemeDialogState extends State<_CustomThemeDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = l10n(context);
    final theme = Theme.of(context);

    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 560),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.max,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(l.themeImport, style: theme.textTheme.headlineSmall),
              const SizedBox(height: 8),
              Text(
                l.themeImportHint,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: TextField(
                  controller: _controller,
                  maxLines: null,
                  expands: true,
                  textAlignVertical: TextAlignVertical.top,
                  decoration: InputDecoration(
                    hintText: ':root { ... }',
                    border: const OutlineInputBorder(),
                    alignLabelWithHint: true,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(l.cancel),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () =>
                        Navigator.of(context).pop(_controller.text),
                    child: Text(l.ok),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
