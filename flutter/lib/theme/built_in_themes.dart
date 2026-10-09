import 'package:flutter/material.dart';

import 'theme_model.dart';

/// Built-in themes shipped with Devinorium.
class BuiltInThemes {
  BuiltInThemes._();

  static const String lightId = 'light';
  static const String darkId = 'dark';
  static const String oledId = 'oled';

  static const ColorTheme light = ColorTheme(
    colors: {
      'primary': Color(0xFF6750A4),
      'on-primary': Color(0xFFFFFFFF),
      'primary-container': Color(0xFFEADDFF),
      'on-primary-container': Color(0xFF21005D),
      'secondary': Color(0xFF625B71),
      'on-secondary': Color(0xFFFFFFFF),
      'secondary-container': Color(0xFFE8DEF8),
      'on-secondary-container': Color(0xFF1D192B),
      'tertiary': Color(0xFF7D5260),
      'on-tertiary': Color(0xFFFFFFFF),
      'tertiary-container': Color(0xFFFFD8E4),
      'on-tertiary-container': Color(0xFF31111D),
      'error': Color(0xFFB3261E),
      'on-error': Color(0xFFFFFFFF),
      'error-container': Color(0xFFF9DEDC),
      'on-error-container': Color(0xFF410E0B),
      'surface': Color(0xFFFFFBFE),
      'on-surface': Color(0xFF1C1B1F),
      'on-surface-variant': Color(0xFF49454F),
      'outline': Color(0xFF79747E),
      'outline-variant': Color(0xFFCAC4D0),
      'shadow': Color(0xFF000000),
      'scrim': Color(0xFF000000),
      'inverse-surface': Color(0xFF313033),
      'on-inverse-surface': Color(0xFFF4EFF4),
      'inverse-primary': Color(0xFFD0BCFF),
      'surface-tint': Color(0xFF6750A4),
      'surface-dim': Color(0xFFDED8E1),
      'surface-bright': Color(0xFFF7F2FA),
      'surface-container-lowest': Color(0xFFFFFFFF),
      'surface-container-low': Color(0xFFF7F2FA),
      'surface-container': Color(0xFFF3EDF7),
      'surface-container-high': Color(0xFFECE6F0),
      'surface-container-highest': Color(0xFFE6E0E9),
      'success': Color(0xFF16A34A),
      'on-success': Color(0xFFFFFFFF),
      'success-container': Color(0xFFDCFCE7),
      'on-success-container': Color(0xFF14532D),
      'warning': Color(0xFFD97706),
      'on-warning': Color(0xFF000000),
      'warning-container': Color(0xFFFEF3C7),
      'on-warning-container': Color(0xFF78350F),
      'info': Color(0xFF0284C7),
      'on-info': Color(0xFFFFFFFF),
      'info-container': Color(0xFFE0F2FE),
      'on-info-container': Color(0xFF0C4A6E),
    },
  );

  static const ColorTheme dark = ColorTheme(
    colors: {
      'primary': Color(0xFFD0BCFF),
      'on-primary': Color(0xFF381E72),
      'primary-container': Color(0xFF3B2D5A),
      'on-primary-container': Color(0xFFEADDFF),
      'secondary': Color(0xFFCCC2DC),
      'on-secondary': Color(0xFF332D41),
      'secondary-container': Color(0xFF25222A),
      'on-secondary-container': Color(0xFFE8DEF8),
      'tertiary': Color(0xFFEFB8C8),
      'on-tertiary': Color(0xFF492532),
      'tertiary-container': Color(0xFF321E23),
      'on-tertiary-container': Color(0xFFFFD8E4),
      'error': Color(0xFFF2B8B5),
      'on-error': Color(0xFF601410),
      'error-container': Color(0xFF4A1513),
      'on-error-container': Color(0xFFF9DEDC),
      'surface': Color(0xFF0A0A0A),
      'on-surface': Color(0xFFFFFFFF),
      'on-surface-variant': Color(0xFFCCCCCC),
      'outline': Color(0xFF7A7A7A),
      'outline-variant': Color(0xFF6B6B6B),
      'shadow': Color(0xFF000000),
      'scrim': Color(0xFF000000),
      'inverse-surface': Color(0xFFFFFFFF),
      'on-inverse-surface': Color(0xFF000000),
      'inverse-primary': Color(0xFF6750A4),
      'surface-tint': Color(0xFFD0BCFF),
      'surface-dim': Color(0xFF070707),
      'surface-bright': Color(0xFF161616),
      'surface-container-lowest': Color(0xFF050505),
      'surface-container-low': Color(0xFF0A0A0A),
      'surface-container': Color(0xFF111111),
      'surface-container-high': Color(0xFF171717),
      'surface-container-highest': Color(0xFF1E1E1E),
      'success': Color(0xFF22C55E),
      'on-success': Color(0xFF052E16),
      'success-container': Color(0xFF14532D),
      'on-success-container': Color(0xFFDCFCE7),
      'warning': Color(0xFFF59E0B),
      'on-warning': Color(0xFF451A03),
      'warning-container': Color(0xFF78350F),
      'on-warning-container': Color(0xFFFEF3C7),
      'info': Color(0xFF0EA5E9),
      'on-info': Color(0xFF082F49),
      'info-container': Color(0xFF0C4A6E),
      'on-info-container': Color(0xFFE0F2FE),
    },
  );

  static const ColorTheme oled = ColorTheme(
    colors: {
      'primary': Color(0xFFD0BCFF),
      'on-primary': Color(0xFF000000),
      'primary-container': Color(0xFF2A1B4A),
      'on-primary-container': Color(0xFFEADDFF),
      'secondary': Color(0xFFCCC2DC),
      'on-secondary': Color(0xFF000000),
      'secondary-container': Color(0xFF2A2630),
      'on-secondary-container': Color(0xFFE8DEF8),
      'tertiary': Color(0xFFEFB8C8),
      'on-tertiary': Color(0xFF000000),
      'tertiary-container': Color(0xFF3D252B),
      'on-tertiary-container': Color(0xFFFFD8E4),
      'error': Color(0xFFF2B8B5),
      'on-error': Color(0xFF000000),
      'error-container': Color(0xFF4A1513),
      'on-error-container': Color(0xFFF9DEDC),
      'surface': Color(0xFF000000),
      'on-surface': Color(0xFFFFFFFF),
      'on-surface-variant': Color(0xFFB3B3B3),
      'outline': Color(0xFF5A5A5A),
      'outline-variant': Color(0xFF333333),
      'shadow': Color(0xFF000000),
      'scrim': Color(0xFF000000),
      'inverse-surface': Color(0xFFFFFFFF),
      'on-inverse-surface': Color(0xFF000000),
      'inverse-primary': Color(0xFF6750A4),
      'surface-tint': Color(0xFFD0BCFF),
      'surface-dim': Color(0xFF000000),
      'surface-bright': Color(0xFF1A1A1A),
      'surface-container-lowest': Color(0xFF000000),
      'surface-container-low': Color(0xFF0A0A0A),
      'surface-container': Color(0xFF111111),
      'surface-container-high': Color(0xFF181818),
      'surface-container-highest': Color(0xFF1F1F1F),
      'success': Color(0xFF22C55E),
      'on-success': Color(0xFF052E16),
      'success-container': Color(0xFF14532D),
      'on-success-container': Color(0xFFDCFCE7),
      'warning': Color(0xFFF59E0B),
      'on-warning': Color(0xFF451A03),
      'warning-container': Color(0xFF78350F),
      'on-warning-container': Color(0xFFFEF3C7),
      'info': Color(0xFF0EA5E9),
      'on-info': Color(0xFF082F49),
      'info-container': Color(0xFF0C4A6E),
      'on-info-container': Color(0xFFE0F2FE),
    },
  );

  static ColorTheme byId(String id) {
    switch (id) {
      case lightId:
        return light;
      case darkId:
        return dark;
      case oledId:
        return oled;
      default:
        return light;
    }
  }
}
