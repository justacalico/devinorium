// Conditional import:
// - Desktop (Linux/macOS/Windows): spawns the bundled devinorium binary
// - Web/mobile/test stub: reports unsupported, never spawns
export 'local_server_types.dart';
export 'local_server_stub.dart'
    if (dart.library.io) 'local_server_io.dart';
