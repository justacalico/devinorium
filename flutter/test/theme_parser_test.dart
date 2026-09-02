import 'package:devinorium_frontend/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ThemeParser', () {
    const validCss = '''
/* @theme
 * version: 1.2.3
 * creator: Ada Lovelace
 * description: A test theme.
 */

:root {
  --primary: #6750A4;
  --on-primary: #FFFFFF;
  --surface: #000000;
  --on-surface: #FFFFFFFF;
}
''';

    test('parses metadata and colors', () {
      final theme = ThemeParser.parse(validCss, name: 'Test');

      expect(theme.name, 'Test');
      expect(theme.metadata.version, '1.2.3');
      expect(theme.metadata.creator, 'Ada Lovelace');
      expect(theme.metadata.description, 'A test theme.');

      expect(theme.colors['primary'], const Color(0xFF6750A4));
      expect(theme.colors['on-primary'], const Color(0xFFFFFFFF));
      expect(theme.colors['surface'], const Color(0xFF000000));
      expect(theme.colors['on-surface'], const Color(0xFFFFFFFF));
    });

    test('rejects standard selectors', () {
      const css = '''
/* @theme */
body { color: red; }
:root {
  --primary: #6750A4;
}
''';
      expect(
        () => ThemeParser.parse(css),
        throwsA(isA<ThemeParseException>().having(
          (e) => e.message,
          'message',
          contains(':root'),
        )),
      );
    });

    test('rejects at-rules', () {
      const css = '''
/* @theme */
@media (prefers-color-scheme: dark) {
  :root {
    --primary: #000000;
  }
}
''';
      expect(
        () => ThemeParser.parse(css),
        throwsA(isA<ThemeParseException>()),
      );
    });

    test('rejects layout properties', () {
      const css = '''
/* @theme */
:root {
  --primary: #6750A4;
  --display: block;
}
''';
      expect(
        () => ThemeParser.parse(css),
        throwsA(isA<ThemeParseException>().having(
          (e) => e.message,
          'message',
          contains('display'),
        )),
      );
    });

    test('rejects unknown theme tokens', () {
      const css = '''
/* @theme */
:root {
  --primary: #6750A4;
  --unknown-token: #000000;
}
''';
      expect(
        () => ThemeParser.parse(css),
        throwsA(isA<ThemeParseException>().having(
          (e) => e.message,
          'message',
          contains('unknown theme color token'),
        )),
      );
    });

    test('rejects non-hex colour values', () {
      const css = '''
/* @theme */
:root {
  --primary: rgb(0, 0, 0);
}
''';
      expect(
        () => ThemeParser.parse(css),
        throwsA(isA<ThemeParseException>().having(
          (e) => e.message,
          'message',
          contains('hex color'),
        )),
      );
    });

    test('accepts eight-digit hex colours', () {
      const css = '''
/* @theme */
:root {
  --primary: #806750A4;
}
''';
      final theme = ThemeParser.parse(css);
      expect(theme.colors['primary'], const Color(0x806750A4));
    });

    test('provides default metadata when @theme block is missing', () {
      const css = '''
:root {
  --primary: #6750A4;
}
''';
      final theme = ThemeParser.parse(css);
      expect(theme.metadata.version, '1.0.0');
      expect(theme.metadata.creator, '');
      expect(theme.metadata.description, '');
    });

    test('built-in themes parse without errors', () {
      expect(BuiltInThemes.light.name, 'Light');
      expect(BuiltInThemes.dark.name, 'Dark');
      expect(BuiltInThemes.oled.name, 'OLED');

      expect(BuiltInThemes.light.toColorScheme(Brightness.light).primary,
          const Color(0xFF6750A4));
      expect(BuiltInThemes.dark.toColorScheme(Brightness.dark).surface,
          const Color(0xFF1C1B1F));
      expect(BuiltInThemes.oled.toColorScheme(Brightness.dark).surface,
          Colors.black);
    });

    test('system theme choice resolves to light or dark', () {
      const light = SystemThemeChoice();
      expect(light.builtInId, isNull);
      expect(light.customCss, isNull);
      expect(light.type, 'system');

      final provider = ThemeProvider(
        platformBrightness: Brightness.dark,
        initialChoice: const SystemThemeChoice(),
      );
      expect(provider.themeMode, ThemeMode.system);
      expect(provider.darkTheme.colorScheme.surface, const Color(0xFF1C1B1F));
      expect(provider.lightTheme.colorScheme.surface, const Color(0xFFFFFBFE));
    });
  });
}
