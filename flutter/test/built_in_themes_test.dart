import 'package:devinorium_frontend/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BuiltInThemes', () {
    // The token values below pin the exact shipped palettes; they guard the
    // hand-maintained maps in built_in_themes.dart against transcription
    // typos.
    const expectedLight = {
      'primary': 0xFF6750A4,
      'on-primary': 0xFFFFFFFF,
      'primary-container': 0xFFEADDFF,
      'on-primary-container': 0xFF21005D,
      'secondary': 0xFF625B71,
      'on-secondary': 0xFFFFFFFF,
      'secondary-container': 0xFFE8DEF8,
      'on-secondary-container': 0xFF1D192B,
      'tertiary': 0xFF7D5260,
      'on-tertiary': 0xFFFFFFFF,
      'tertiary-container': 0xFFFFD8E4,
      'on-tertiary-container': 0xFF31111D,
      'error': 0xFFB3261E,
      'on-error': 0xFFFFFFFF,
      'error-container': 0xFFF9DEDC,
      'on-error-container': 0xFF410E0B,
      'surface': 0xFFFFFBFE,
      'on-surface': 0xFF1C1B1F,
      'on-surface-variant': 0xFF49454F,
      'outline': 0xFF79747E,
      'outline-variant': 0xFFCAC4D0,
      'shadow': 0xFF000000,
      'scrim': 0xFF000000,
      'inverse-surface': 0xFF313033,
      'on-inverse-surface': 0xFFF4EFF4,
      'inverse-primary': 0xFFD0BCFF,
      'surface-tint': 0xFF6750A4,
      'surface-dim': 0xFFDED8E1,
      'surface-bright': 0xFFF7F2FA,
      'surface-container-lowest': 0xFFFFFFFF,
      'surface-container-low': 0xFFF7F2FA,
      'surface-container': 0xFFF3EDF7,
      'surface-container-high': 0xFFECE6F0,
      'surface-container-highest': 0xFFE6E0E9,
      'success': 0xFF16A34A,
      'on-success': 0xFFFFFFFF,
      'success-container': 0xFFDCFCE7,
      'on-success-container': 0xFF14532D,
      'warning': 0xFFD97706,
      'on-warning': 0xFF000000,
      'warning-container': 0xFFFEF3C7,
      'on-warning-container': 0xFF78350F,
      'info': 0xFF0284C7,
      'on-info': 0xFFFFFFFF,
      'info-container': 0xFFE0F2FE,
      'on-info-container': 0xFF0C4A6E,
    };

    const expectedDark = {
      'primary': 0xFFD0BCFF,
      'on-primary': 0xFF381E72,
      'primary-container': 0xFF3B2D5A,
      'on-primary-container': 0xFFEADDFF,
      'secondary': 0xFFCCC2DC,
      'on-secondary': 0xFF332D41,
      'secondary-container': 0xFF25222A,
      'on-secondary-container': 0xFFE8DEF8,
      'tertiary': 0xFFEFB8C8,
      'on-tertiary': 0xFF492532,
      'tertiary-container': 0xFF321E23,
      'on-tertiary-container': 0xFFFFD8E4,
      'error': 0xFFF2B8B5,
      'on-error': 0xFF601410,
      'error-container': 0xFF4A1513,
      'on-error-container': 0xFFF9DEDC,
      'surface': 0xFF0A0A0A,
      'on-surface': 0xFFFFFFFF,
      'on-surface-variant': 0xFFCCCCCC,
      'outline': 0xFF7A7A7A,
      'outline-variant': 0xFF6B6B6B,
      'shadow': 0xFF000000,
      'scrim': 0xFF000000,
      'inverse-surface': 0xFFFFFFFF,
      'on-inverse-surface': 0xFF000000,
      'inverse-primary': 0xFF6750A4,
      'surface-tint': 0xFFD0BCFF,
      'surface-dim': 0xFF070707,
      'surface-bright': 0xFF161616,
      'surface-container-lowest': 0xFF050505,
      'surface-container-low': 0xFF0A0A0A,
      'surface-container': 0xFF111111,
      'surface-container-high': 0xFF171717,
      'surface-container-highest': 0xFF1E1E1E,
      'success': 0xFF22C55E,
      'on-success': 0xFF052E16,
      'success-container': 0xFF14532D,
      'on-success-container': 0xFFDCFCE7,
      'warning': 0xFFF59E0B,
      'on-warning': 0xFF451A03,
      'warning-container': 0xFF78350F,
      'on-warning-container': 0xFFFEF3C7,
      'info': 0xFF0EA5E9,
      'on-info': 0xFF082F49,
      'info-container': 0xFF0C4A6E,
      'on-info-container': 0xFFE0F2FE,
    };

    const expectedOled = {
      'primary': 0xFFD0BCFF,
      'on-primary': 0xFF000000,
      'primary-container': 0xFF2A1B4A,
      'on-primary-container': 0xFFEADDFF,
      'secondary': 0xFFCCC2DC,
      'on-secondary': 0xFF000000,
      'secondary-container': 0xFF2A2630,
      'on-secondary-container': 0xFFE8DEF8,
      'tertiary': 0xFFEFB8C8,
      'on-tertiary': 0xFF000000,
      'tertiary-container': 0xFF3D252B,
      'on-tertiary-container': 0xFFFFD8E4,
      'error': 0xFFF2B8B5,
      'on-error': 0xFF000000,
      'error-container': 0xFF4A1513,
      'on-error-container': 0xFFF9DEDC,
      'surface': 0xFF000000,
      'on-surface': 0xFFFFFFFF,
      'on-surface-variant': 0xFFB3B3B3,
      'outline': 0xFF5A5A5A,
      'outline-variant': 0xFF333333,
      'shadow': 0xFF000000,
      'scrim': 0xFF000000,
      'inverse-surface': 0xFFFFFFFF,
      'on-inverse-surface': 0xFF000000,
      'inverse-primary': 0xFF6750A4,
      'surface-tint': 0xFFD0BCFF,
      'surface-dim': 0xFF000000,
      'surface-bright': 0xFF1A1A1A,
      'surface-container-lowest': 0xFF000000,
      'surface-container-low': 0xFF0A0A0A,
      'surface-container': 0xFF111111,
      'surface-container-high': 0xFF181818,
      'surface-container-highest': 0xFF1F1F1F,
      'success': 0xFF22C55E,
      'on-success': 0xFF052E16,
      'success-container': 0xFF14532D,
      'on-success-container': 0xFFDCFCE7,
      'warning': 0xFFF59E0B,
      'on-warning': 0xFF451A03,
      'warning-container': 0xFF78350F,
      'on-warning-container': 0xFFFEF3C7,
      'info': 0xFF0EA5E9,
      'on-info': 0xFF082F49,
      'info-container': 0xFF0C4A6E,
      'on-info-container': 0xFFE0F2FE,
    };

    void expectColors(ColorTheme theme, Map<String, int> expected) {
      expect(theme.colors.keys.toSet(), expected.keys.toSet());
      for (final entry in expected.entries) {
        expect(
          theme.colors[entry.key],
          Color(entry.value),
          reason: 'token "${entry.key}"',
        );
      }
    }

    test('light theme defines the expected palette', () {
      expectColors(BuiltInThemes.light, expectedLight);
    });

    test('dark theme defines the expected palette', () {
      expectColors(BuiltInThemes.dark, expectedDark);
    });

    test('oled theme defines the expected palette', () {
      expectColors(BuiltInThemes.oled, expectedOled);
    });

    test('oled surfaces are pure black where dark uses near-black', () {
      expect(BuiltInThemes.oled['surface'], const Color(0xFF000000));
      expect(BuiltInThemes.dark['surface'], const Color(0xFF0A0A0A));
      expect(
        BuiltInThemes.oled['surface-container-lowest'],
        const Color(0xFF000000),
      );
      expect(
        BuiltInThemes.dark['surface-container-lowest'],
        const Color(0xFF050505),
      );
    });

    test('byId resolves each built-in id and defaults to light', () {
      expect(BuiltInThemes.byId(BuiltInThemes.lightId), BuiltInThemes.light);
      expect(BuiltInThemes.byId(BuiltInThemes.darkId), BuiltInThemes.dark);
      expect(BuiltInThemes.byId(BuiltInThemes.oledId), BuiltInThemes.oled);
      expect(BuiltInThemes.byId('nope'), BuiltInThemes.light);
    });

    test('themes build ThemeData with semantic colors extension', () {
      for (final theme in [BuiltInThemes.light, BuiltInThemes.dark]) {
        final data = theme.toThemeData(Brightness.light);
        expect(data.useMaterial3, isTrue);
        expect(data.extension<SemanticColors>(), isNotNull);
      }
    });
  });
}
