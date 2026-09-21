// Conditional import:
// - IO (Android/iOS/desktop): flutter_local_notifications on mobile, OS
//   shell-outs (notify-send, osascript, PowerShell) on desktop. io is checked
//   first because dart.library.js_interop exists on native too.
// - Web: Notifications API in-page + Web Push via the /push/ service worker
// - Anything else (tests): no-op stub
export 'notification_service_stub.dart'
    if (dart.library.io) 'notification_service_io.dart'
    if (dart.library.js_interop) 'notification_service_web.dart';
