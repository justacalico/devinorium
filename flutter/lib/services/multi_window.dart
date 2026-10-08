// Conditional import:
// - Desktop (Linux/Windows): marker file the runners check before taking
//   the single-instance path
// - Everything else: reports unsupported, never touches the filesystem
export 'multi_window_types.dart';
export 'multi_window_stub.dart' if (dart.library.io) 'multi_window_io.dart';
