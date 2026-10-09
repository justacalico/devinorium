import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'built_in_themes.dart';
import 'theme_model.dart';

/// Provides the current [ThemeData] and persists the user's choice.
///
/// A choice can be one of the built-in themes or `system` which loads the
/// built-in light or dark theme based on the platform brightness.
class ThemeProvider extends ChangeNotifier {
  ThemeProvider({
    this._prefs,
    Brightness? platformBrightness,
    ThemeChoice? initialChoice,
  }) : _platformBrightness = platformBrightness ?? Brightness.light,
       _choice = initialChoice ?? const SystemThemeChoice();

  final SharedPreferences? _prefs;
  Brightness _platformBrightness;
  ThemeChoice _choice;

  ThemeChoice get choice => _choice;
  Brightness get platformBrightness => _platformBrightness;

  static const _key = 'devinorium_theme_choice';
  static const _legacyKey = 'devinorium_theme_mode';

  /// Initializes from [SharedPreferences], migrating a legacy `ThemeMode` if
  /// no new choice is saved yet.
  Future<void> loadInitial() async {
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    final json = prefs.getString(_key);

    if (json != null && json.isNotEmpty) {
      try {
        _choice = ThemeChoice.fromJson(
          jsonDecode(json) as Map<String, dynamic>,
        );
      } catch (_) {
        _choice = const SystemThemeChoice();
      }
    } else {
      _choice = _migrateLegacy(prefs.getString(_legacyKey));
    }

    notifyListeners();
  }

  /// Updates the platform brightness (usually from
  /// `MediaQuery.platformBrightnessOf`).
  void setPlatformBrightness(Brightness brightness) {
    if (_platformBrightness == brightness) return;
    _platformBrightness = brightness;
    notifyListeners();
  }

  Future<void> selectSystem() async {
    _choice = const SystemThemeChoice();
    await _save();
    notifyListeners();
  }

  Future<void> selectBuiltIn(String id) async {
    _choice = BuiltInThemeChoice(id);
    await _save();
    notifyListeners();
  }

  /// The [ThemeData] to use when the platform is in light mode.
  ThemeData get lightTheme {
    final effective = _effectiveLightTheme;
    return effective.toThemeData(Brightness.light);
  }

  /// The [ThemeData] to use when the platform is in dark mode.
  ThemeData get darkTheme {
    final effective = _effectiveDarkTheme;
    return effective.toThemeData(Brightness.dark);
  }

  /// The [ThemeMode] to pass to [MaterialApp].
  ThemeMode get themeMode => switch (_choice) {
    SystemThemeChoice() => ThemeMode.system,
    BuiltInThemeChoice(:final id) when id == BuiltInThemes.lightId =>
      ThemeMode.light,
    BuiltInThemeChoice(:final id)
        when id == BuiltInThemes.darkId || id == BuiltInThemes.oledId =>
      ThemeMode.dark,
    BuiltInThemeChoice() => ThemeMode.light,
  };

  /// Whether the active theme is dark for the current platform brightness.
  bool get isActiveDark => _activeBrightness == Brightness.dark;

  /// The brightness the active choice resolves to right now.
  Brightness get _activeBrightness => switch (_choice) {
    SystemThemeChoice() => _platformBrightness,
    BuiltInThemeChoice(:final id) when id == BuiltInThemes.lightId =>
      Brightness.light,
    BuiltInThemeChoice(:final id)
        when id == BuiltInThemes.darkId || id == BuiltInThemes.oledId =>
      Brightness.dark,
    BuiltInThemeChoice() => Brightness.light,
  };

  ColorTheme get _effectiveLightTheme => switch (_choice) {
    SystemThemeChoice() => BuiltInThemes.light,
    BuiltInThemeChoice(:final id) => BuiltInThemes.byId(id),
  };

  ColorTheme get _effectiveDarkTheme => switch (_choice) {
    SystemThemeChoice() => BuiltInThemes.dark,
    BuiltInThemeChoice(:final id) => BuiltInThemes.byId(id),
  };

  ColorTheme get activeTheme {
    final brightness = _activeBrightness;
    return brightness == Brightness.light
        ? _effectiveLightTheme
        : _effectiveDarkTheme;
  }

  Future<void> _save() async {
    try {
      final prefs = _prefs ?? await SharedPreferences.getInstance();
      await prefs.setString(_key, jsonEncode(_choice.toJson()));
    } catch (e) {
      if (kDebugMode) debugPrint('Failed to save theme choice: $e');
    }
  }

  static ThemeChoice _migrateLegacy(String? value) {
    return switch (value) {
      'light' => const BuiltInThemeChoice(BuiltInThemes.lightId),
      'dark' => const BuiltInThemeChoice(BuiltInThemes.darkId),
      _ => const SystemThemeChoice(),
    };
  }
}
