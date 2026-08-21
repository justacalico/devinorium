// Conditional import: the web implementation uses package:web and
// dart:js_interop, which are not available in the VM test runner.
export 'notification_service_stub.dart'
    if (dart.library.js_interop) 'notification_service_web.dart';
