import 'dart:convert';

import 'package:devinorium_frontend/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('ThemeProvider', () {
    const customCss = '''
/* @theme
 * version: 2.0.0
 * creator: Test Creator
 * description: A custom dark theme.
 */

:root {
  --primary: #FF0000;
  --surface: #111111;
  --on-surface: #FFFFFF;
}
''';

    Future<SharedPreferences> mockPrefs(Map<String, Object> values) async {
      SharedPreferences.setMockInitialValues(values);
      return SharedPreferences.getInstance();
    }

    test('defaults to system and uses built-in light/dark themes', () {
      final provider = ThemeProvider(
        platformBrightness: Brightness.light,
        initialChoice: const SystemThemeChoice(),
      );
      expect(provider.themeMode, ThemeMode.system);
      expect(provider.lightTheme.colorScheme.surface, const Color(0xFFFFFBFE));
      expect(provider.darkTheme.colorScheme.surface, const Color(0xFF1C1B1F));
    });

    test('built-in dark theme is always dark', () async {
      final provider = ThemeProvider(
        platformBrightness: Brightness.light,
        initialChoice: const BuiltInThemeChoice(BuiltInThemes.darkId),
      );
      expect(provider.themeMode, ThemeMode.dark);
      expect(provider.lightTheme.colorScheme.surface, const Color(0xFF1C1B1F));
    });

    test('built-in OLED uses pure black surfaces', () async {
      final provider = ThemeProvider(
        platformBrightness: Brightness.dark,
        initialChoice: const BuiltInThemeChoice(BuiltInThemes.oledId),
      );
      expect(provider.themeMode, ThemeMode.dark);
      expect(provider.darkTheme.colorScheme.surface, Colors.black);
    });

    test('loads and saves a built-in choice to SharedPreferences', () async {
      final prefs = await mockPrefs({});
      final provider = ThemeProvider(prefs: prefs);
      await provider.selectBuiltIn(BuiltInThemes.darkId);

      final stored = prefs.getString('devinorium_theme_choice');
      expect(stored, isNotNull);
      final json = jsonDecode(stored!) as Map<String, dynamic>;
      expect(json['type'], 'builtIn');
      expect(json['id'], 'dark');

      final restored = ThemeProvider(prefs: prefs);
      await restored.loadInitial();
      expect(restored.choice, const BuiltInThemeChoice(BuiltInThemes.darkId));
      expect(restored.themeMode, ThemeMode.dark);
    });

    test('loadCustom parses and persists CSS', () async {
      final prefs = await mockPrefs({});
      final provider = ThemeProvider(prefs: prefs);
      await provider.loadCustom(customCss, name: 'My Theme');

      expect(provider.choice, const CustomThemeChoice(customCss, name: 'My Theme'));
      expect(provider.activeTheme.metadata.creator, 'Test Creator');
      expect(provider.activeTheme.metadata.version, '2.0.0');
      expect(provider.activeTheme.colors['primary'], const Color(0xFFFF0000));
      expect(provider.activeTheme.colors['surface'], const Color(0xFF111111));

      final stored = prefs.getString('devinorium_theme_choice');
      final json = jsonDecode(stored!) as Map<String, dynamic>;
      expect(json['type'], 'custom');
      expect(json['css'], customCss);
      expect(json['name'], 'My Theme');
    });

    test('restores a custom theme from SharedPreferences', () async {
      final prefs = await mockPrefs({
        'devinorium_theme_choice': jsonEncode({
          'type': 'custom',
          'css': customCss,
          'name': 'Saved',
        }),
      });
      final provider = ThemeProvider(prefs: prefs);
      await provider.loadInitial();

      expect(provider.choice, const CustomThemeChoice(customCss, name: 'Saved'));
      expect(provider.activeTheme.name, 'Saved');
      expect(provider.activeTheme.metadata.creator, 'Test Creator');
    });

    test('migrates legacy theme mode to built-in choice', () async {
      final prefs = await mockPrefs({'devinorium_theme_mode': 'dark'});
      final provider = ThemeProvider(prefs: prefs);
      await provider.loadInitial();

      expect(provider.choice, const BuiltInThemeChoice(BuiltInThemes.darkId));
      expect(provider.themeMode, ThemeMode.dark);
    });

    test('setPlatformBrightness notifies listeners and changes active theme', () {
      final provider = ThemeProvider(
        platformBrightness: Brightness.light,
        initialChoice: const SystemThemeChoice(),
      );
      expect(
        provider.activeTheme.toColorScheme(Brightness.light).surface,
        const Color(0xFFFFFBFE),
      );

      var notified = false;
      provider.addListener(() => notified = true);
      provider.setPlatformBrightness(Brightness.dark);

      expect(notified, isTrue);
      expect(
        provider.activeTheme.toColorScheme(Brightness.dark).surface,
        const Color(0xFF1C1B1F),
      );
    });

    test('loadCustom throws ThemeParseException for invalid CSS', () async {
      final prefs = await mockPrefs({});
      final provider = ThemeProvider(prefs: prefs);
      expect(
        () => provider.loadCustom(':root { --display: block; }'),
        throwsA(isA<ThemeParseException>()),
      );
    });

    test('clearCustom selects the light built-in theme', () async {
      final prefs = await mockPrefs({});
      final provider = ThemeProvider(prefs: prefs);
      await provider.loadCustom(customCss, name: 'My Theme');
      await provider.clearCustom();

      expect(provider.choice, const BuiltInThemeChoice(BuiltInThemes.lightId));
      expect(provider.hasValidCustomTheme, isFalse);
      expect(provider.themeMode, ThemeMode.light);
    });

    test('restoring an invalid custom theme falls back to built-in', () async {
      final prefs = await mockPrefs({
        'devinorium_theme_choice': jsonEncode({
          'type': 'custom',
          'css': ':root { --display: block; }',
          'name': 'Broken',
        }),
      });
      final provider = ThemeProvider(prefs: prefs);
      await provider.loadInitial();

      expect(provider.choice, isA<CustomThemeChoice>());
      expect(provider.hasValidCustomTheme, isFalse);
      expect(
        provider.activeTheme.toColorScheme(Brightness.light).surface,
        const Color(0xFFFFFBFE),
      );
    });

    test('setPlatformBrightness with a custom theme keeps system mode', () {
      final provider = ThemeProvider(
        platformBrightness: Brightness.light,
        initialChoice: const CustomThemeChoice(
          '''
/* @theme */
:root {
  --primary: #FF0000;
  --surface: #111111;
  --on-surface: #FFFFFF;
}
''',
          name: 'Red',
        ),
      );
      expect(provider.themeMode, ThemeMode.system);
      expect(provider.activeTheme.name, 'Red');

      provider.setPlatformBrightness(Brightness.dark);
      expect(provider.activeTheme.name, 'Red');
      expect(
        provider.activeTheme.toColorScheme(Brightness.dark).surface,
        const Color(0xFF111111),
      );
    });

    test('migrates an unknown legacy theme mode to system', () async {
      final prefs = await mockPrefs({'devinorium_theme_mode': 'oled'});
      final provider = ThemeProvider(prefs: prefs);
      await provider.loadInitial();

      expect(provider.choice, const SystemThemeChoice());
      expect(provider.themeMode, ThemeMode.system);
    });
  });
}
