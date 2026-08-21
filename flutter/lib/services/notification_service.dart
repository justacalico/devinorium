// Conditional import:
// - Web: browser Notifications API + Web Audio API
// - Desktop (Linux/macOS/Windows): native OS commands
// - Mobile/test stub: no-op
export 'notification_service_stub.dart'
    if (dart.library.js_interop) 'notification_service_web.dart'
    if (dart.library.io) 'notification_service_io.dart';
