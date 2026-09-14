import 'package:flutter/material.dart';

import 'pwa_chrome_stub.dart'
    if (dart.library.js_interop) 'pwa_chrome_web.dart';

/// Syncs the host browser/PWA chrome with the app theme.
///
/// iOS standalone web apps color the status bar from `theme-color` (iOS 15+)
/// and iOS 26 Safari tints its chrome from the document background, so both
/// are kept aligned with [surface]. The `prefers-color-scheme` meta tags in
/// index.html only cover first paint; once Flutter resolves the in-app theme
/// it wins over the OS setting.
void syncPwaChrome(Color surface, bool dark) =>
    syncPwaChromeImpl(colorToHex(surface), dark);

/// #RRGGBB for [color]; alpha is dropped since theme-color ignores it.
String colorToHex(Color color) =>
    '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';
