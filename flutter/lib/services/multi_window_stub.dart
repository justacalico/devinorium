import 'multi_window_types.dart';

/// Stub for platforms without an app-level single-instance check (web,
/// mobile, tests). Always reports unsupported.
class MultiWindowPreference implements MultiWindowStore {
  MultiWindowPreference();

  /// A store that reports unsupported and never touches the filesystem.
  /// Used by [AppState.test] so tests stay hermetic.
  factory MultiWindowPreference.disabled() => MultiWindowPreference();

  @override
  bool get isSupported => false;

  @override
  Future<bool> load() async => false;

  @override
  Future<void> setEnabled(bool enabled) async {}
}
