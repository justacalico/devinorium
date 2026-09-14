import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Holds the desktop UI zoom factor and persists it between launches.
///
/// Zoom steps through the same discrete levels browsers use for page zoom,
/// so Ctrl/Cmd + `+`/`-` move between familiar percentages and
/// Ctrl/Cmd + `0` returns to 100%.
class ZoomController extends ChangeNotifier {
  ZoomController({this._prefs});

  /// Whether the current build handles its own zoom shortcuts. On web the
  /// browser owns page zoom, so the app leaves it alone.
  static bool get isDesktop =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.windows);

  static const _key = 'devinorium_zoom_factor';

  static const _levels = <double>[
    0.25,
    0.33,
    0.5,
    0.67,
    0.75,
    0.8,
    0.9,
    1.0,
    1.1,
    1.25,
    1.5,
    1.75,
    2.0,
    2.5,
    3.0,
    4.0,
    5.0,
  ];

  SharedPreferences? _prefs;
  double _factor = 1.0;

  double get factor => _factor;

  /// The factor as a rounded percentage for display (`1.1` -> `110`).
  int get percent => (_factor * 100).round();

  Future<void> load() async {
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    final stored = prefs.getDouble(_key);
    if (stored != null && stored >= _levels.first && stored <= _levels.last) {
      _factor = stored;
      notifyListeners();
    }
  }

  void zoomIn() => _setFactor(_step(1));

  void zoomOut() => _setFactor(_step(-1));

  void reset() => _setFactor(1.0);

  double _step(int direction) {
    if (direction > 0) {
      for (final level in _levels) {
        if (level > _factor + 0.001) return level;
      }
      return _levels.last;
    }
    for (var i = _levels.length - 1; i >= 0; i--) {
      if (_levels[i] < _factor - 0.001) return _levels[i];
    }
    return _levels.first;
  }

  void _setFactor(double value) {
    if ((value - _factor).abs() < 0.001) return;
    _factor = value;
    notifyListeners();
    unawaited(_save());
  }

  Future<void> _save() async {
    try {
      final prefs = _prefs ??= await SharedPreferences.getInstance();
      await prefs.setDouble(_key, _factor);
    } catch (_) {
      // Zoom persistence is best-effort.
    }
  }
}
