import 'theme_model.dart';
import 'theme_parser.dart';

/// Built-in themes shipped with Devinorium.
///
/// Each theme is stored as a restricted CSS string so the parser can treat
/// built-ins and user-supplied files the same way.
class BuiltInThemes {
  BuiltInThemes._();

  static const String lightId = 'light';
  static const String darkId = 'dark';
  static const String oledId = 'oled';

  static const lightCss = '''
/* @theme
 * version: 1.0.0
 * creator: Devinorium
 * description: The default Material 3 light theme.
 */

:root {
  --primary: #6750A4;
  --on-primary: #FFFFFF;
  --primary-container: #EADDFF;
  --on-primary-container: #21005D;
  --secondary: #625B71;
  --on-secondary: #FFFFFF;
  --secondary-container: #E8DEF8;
  --on-secondary-container: #1D192B;
  --tertiary: #7D5260;
  --on-tertiary: #FFFFFF;
  --tertiary-container: #FFD8E4;
  --on-tertiary-container: #31111D;
  --error: #B3261E;
  --on-error: #FFFFFF;
  --error-container: #F9DEDC;
  --on-error-container: #410E0B;
  --surface: #FFFBFE;
  --on-surface: #1C1B1F;
  --on-surface-variant: #49454F;
  --outline: #79747E;
  --outline-variant: #CAC4D0;
  --shadow: #000000;
  --scrim: #000000;
  --inverse-surface: #313033;
  --on-inverse-surface: #F4EFF4;
  --inverse-primary: #D0BCFF;
  --surface-tint: #6750A4;
  --surface-dim: #DED8E1;
  --surface-bright: #F7F2FA;
  --surface-container-lowest: #FFFFFF;
  --surface-container-low: #F7F2FA;
  --surface-container: #F3EDF7;
  --surface-container-high: #ECE6F0;
  --surface-container-highest: #E6E0E9;
}
''';

  static const darkCss = '''
/* @theme
 * version: 1.0.0
 * creator: Devinorium
 * description: The default Material 3 dark theme.
 */

:root {
  --primary: #D0BCFF;
  --on-primary: #381E72;
  --primary-container: #4F378B;
  --on-primary-container: #EADDFF;
  --secondary: #CCC2DC;
  --on-secondary: #332D41;
  --secondary-container: #4A4458;
  --on-secondary-container: #E8DEF8;
  --tertiary: #EFB8C8;
  --on-tertiary: #492532;
  --tertiary-container: #633B48;
  --on-tertiary-container: #FFD8E4;
  --error: #F2B8B5;
  --on-error: #601410;
  --error-container: #8C1D18;
  --on-error-container: #F9DEDC;
  --surface: #1C1B1F;
  --on-surface: #E3E2E6;
  --on-surface-variant: #CAC4D0;
  --outline: #938F99;
  --outline-variant: #49454F;
  --shadow: #000000;
  --scrim: #000000;
  --inverse-surface: #E3E2E6;
  --on-inverse-surface: #313033;
  --inverse-primary: #6750A4;
  --surface-tint: #D0BCFF;
  --surface-dim: #141218;
  --surface-bright: #3B383E;
  --surface-container-lowest: #0F0D13;
  --surface-container-low: #1C1B1F;
  --surface-container: #211F26;
  --surface-container-high: #2B2930;
  --surface-container-highest: #36343B;
}
''';

  static const oledCss = '''
/* @theme
 * version: 1.0.0
 * creator: Devinorium
 * description: A pure black theme designed for OLED displays.
 */

:root {
  --primary: #D0BCFF;
  --on-primary: #000000;
  --primary-container: #2A1B4A;
  --on-primary-container: #EADDFF;
  --secondary: #CCC2DC;
  --on-secondary: #000000;
  --secondary-container: #2A2630;
  --on-secondary-container: #E8DEF8;
  --tertiary: #EFB8C8;
  --on-tertiary: #000000;
  --tertiary-container: #3D252B;
  --on-tertiary-container: #FFD8E4;
  --error: #F2B8B5;
  --on-error: #000000;
  --error-container: #4A1513;
  --on-error-container: #F9DEDC;
  --surface: #000000;
  --on-surface: #FFFFFF;
  --on-surface-variant: #B3B3B3;
  --outline: #5A5A5A;
  --outline-variant: #333333;
  --shadow: #000000;
  --scrim: #000000;
  --inverse-surface: #FFFFFF;
  --on-inverse-surface: #000000;
  --inverse-primary: #6750A4;
  --surface-tint: #D0BCFF;
  --surface-dim: #000000;
  --surface-bright: #1A1A1A;
  --surface-container-lowest: #000000;
  --surface-container-low: #0A0A0A;
  --surface-container: #111111;
  --surface-container-high: #181818;
  --surface-container-highest: #1F1F1F;
}
''';

  static final ColorTheme light = ThemeParser.parse(lightCss, name: 'Light');
  static final ColorTheme dark = ThemeParser.parse(darkCss, name: 'Dark');
  static final ColorTheme oled = ThemeParser.parse(oledCss, name: 'OLED');

  static final List<ColorTheme> all = [light, dark, oled];

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

  static String cssForId(String id) {
    switch (id) {
      case lightId:
        return lightCss;
      case darkId:
        return darkCss;
      case oledId:
        return oledCss;
      default:
        return lightCss;
    }
  }
}
