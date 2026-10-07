// Conditional import:
// - dart:io platforms: detects installed editors and launches the thread's
//   working directory in them (isSupported is still false on mobile OSes)
// - Web stub: reports unsupported, never spawns
export 'editor_launcher_types.dart';
export 'editor_launcher_stub.dart'
    if (dart.library.io) 'editor_launcher_io.dart';
