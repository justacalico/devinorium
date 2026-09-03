import 'dart:math' as math;

import 'package:devinorium_frontend/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

double _channelLuminance(double value) {
  return value <= 0.03928
      ? value / 12.92
      : math.pow((value + 0.055) / 1.055, 2.4).toDouble();
}

double _relativeLuminance(Color color) {
  return 0.2126 * _channelLuminance(color.r) +
      0.7152 * _channelLuminance(color.g) +
      0.0722 * _channelLuminance(color.b);
}

double _contrast(Color a, Color b) {
  final la = _relativeLuminance(a) + 0.05;
  final lb = _relativeLuminance(b) + 0.05;
  return la > lb ? la / lb : lb / la;
}

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

    test('rejects non-hex color values', () {
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

    test('accepts eight-digit hex colors', () {
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
          const Color(0xFF0A0A0A));
      expect(BuiltInThemes.oled.toColorScheme(Brightness.dark).surface,
          Colors.black);
    });

    test('dark theme uses deep black surfaces and progressively lighter containers', () {
      final scheme = BuiltInThemes.dark.toColorScheme(Brightness.dark);

      expect(scheme.surface, const Color(0xFF0A0A0A));
      expect(scheme.surfaceDim, Colors.black);
      expect(scheme.surfaceBright, const Color(0xFF161616));
      expect(scheme.surfaceContainerLowest, Colors.black);
      expect(scheme.surfaceContainerLow, const Color(0xFF0A0A0A));
      expect(scheme.surfaceContainer, const Color(0xFF111111));
      expect(scheme.surfaceContainerHigh, const Color(0xFF171717));
      expect(scheme.surfaceContainerHighest, const Color(0xFF1E1E1E));
      expect(scheme.onSurface, Colors.white);
    });

    test('dark theme greys remain visible on near-black surfaces', () {
      final scheme = BuiltInThemes.dark.toColorScheme(Brightness.dark);

      expect(scheme.onSurfaceVariant, const Color(0xFFCCCCCC));
      expect(scheme.outline, const Color(0xFF7A7A7A));
      expect(scheme.outlineVariant, const Color(0xFF6B6B6B));

      expect(_contrast(scheme.outline, scheme.surface), greaterThan(3.0));
      expect(
        _contrast(scheme.outlineVariant, scheme.surfaceContainerHighest),
        greaterThan(3.0),
      );

      final dimComment = scheme.onSurfaceVariant.withAlpha(153);
      final blendedComment = Color.alphaBlend(
        dimComment,
        scheme.surfaceContainerHigh,
      );
      expect(
        _contrast(blendedComment, scheme.surfaceContainerHigh),
        greaterThan(4.5),
      );
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
      expect(provider.darkTheme.colorScheme.surface, const Color(0xFF0A0A0A));
      expect(provider.lightTheme.colorScheme.surface, const Color(0xFFFFFBFE));
    });

    test('rejects empty property names', () {
      const css = '''
/* @theme */
:root {
  : #6750A4;
}
''';
      expect(
        () => ThemeParser.parse(css),
        throwsA(isA<ThemeParseException>().having(
          (e) => e.message,
          'message',
          contains('missing property name'),
        )),
      );
    });

    test('rejects nested selectors inside :root', () {
      const css = '''
/* @theme */
:root {
  body {};
  --primary: #6750A4;
}
''';
      expect(
        () => ThemeParser.parse(css),
        throwsA(isA<ThemeParseException>()),
      );
    });

    test('rejects a lone @ character', () {
      const css = '''
/* @theme */
@ :root {
  --primary: #6750A4;
}
''';
      expect(
        () => ThemeParser.parse(css),
        throwsA(isA<ThemeParseException>().having(
          (e) => e.message,
          'message',
          contains('at-rules'),
        )),
      );
    });

    test('rejects unclosed comments', () {
      const css = '''
/* @theme */
/* unclosed
:root {
  --primary: #6750A4;
}
''';
      expect(
        () => ThemeParser.parse(css),
        throwsA(isA<ThemeParseException>().having(
          (e) => e.message,
          'message',
          contains('unclosed comment'),
        )),
      );
    });

    test('parses one-line metadata block', () {
      const css = '/* @theme version: 2.0.0 */\n:root { --primary: #6750A4; }';
      final theme = ThemeParser.parse(css);
      expect(theme.metadata.version, '2.0.0');
      expect(theme.colors['primary'], const Color(0xFF6750A4));
    });

    test('ignores empty name and empty creator', () {
      const css = '''
/* @theme
 * creator:
 */
:root { --primary: #6750A4; }
''';
      final theme = ThemeParser.parse(css, name: '   ');
      expect(theme.name, isNull);
    });
  });
}
