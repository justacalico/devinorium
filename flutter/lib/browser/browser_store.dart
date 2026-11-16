import 'package:flutter/foundation.dart';

/// Open/height state for the agent-browser panel under the thread view.
///
/// The feed connection itself lives in the panel widget: it only exists
/// while the panel is visible, so there is nothing to keep alive here.
class BrowserPanelStore extends ChangeNotifier {
  static const double defaultHeight = 360;
  static const double minHeight = 180;

  bool _open = false;
  bool _disposed = false;
  double _height = defaultHeight;

  bool get open => _open;
  double get height => _height;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void setOpen(bool value) {
    if (_open == value) return;
    _open = value;
    _notify();
  }

  void toggleOpen() => setOpen(!_open);

  void setHeight(double value) {
    final clamped = value < minHeight ? minHeight : value;
    if (_height == clamped) return;
    _height = clamped;
    _notify();
  }

  /// Close the panel on logout and server switches so a stale feed can
  /// never be shown for the wrong connection.
  void clear() {
    _open = false;
    _height = defaultHeight;
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
