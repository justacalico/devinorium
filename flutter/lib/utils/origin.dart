import 'origin_stub.dart' if (dart.library.js_interop) 'origin_web.dart';

/// The current web origin, or an empty string on native.
String currentOrigin() => originImpl();
