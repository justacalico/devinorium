/// Contract for the "multiple windows" desktop preference.
///
/// The platform runners decide single-instance behavior before Dart starts,
/// so the value is persisted as a marker file in the shared per-user data
/// directory (the same one [LocalServerManager] publishes `endpoint.json`
/// into) instead of `SharedPreferences`. A marker named [markerFileName]
/// existing means every later launch opens its own window instead of
/// forwarding activation to the already-running instance.
abstract class MultiWindowStore {
  /// Marker file checked by the Windows and Linux runners at launch.
  static const markerFileName = 'multi_window';

  /// Whether this platform has an app-level single-instance check the
  /// setting can skip. Linux and Windows enforce uniqueness in their
  /// runners; macOS leaves it to LaunchServices, so there is nothing to
  /// skip and the toggle stays hidden there.
  bool get isSupported;

  /// Whether later launches are allowed to open additional windows.
  Future<bool> load();

  /// Persist the choice for future launches. No effect on windows that are
  /// already open.
  Future<void> setEnabled(bool enabled);
}
