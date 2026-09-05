import 'dart:async';
import 'dart:typed_data';

import 'package:pasteboard/pasteboard.dart' as pasteboard;

typedef ClipboardImageGetter = Future<Uint8List?> Function();

ClipboardImageGetter _clipboardImageGetter = () => pasteboard.Pasteboard.image;

Future<Uint8List?> getClipboardImage() => _clipboardImageGetter();

/// Overrides the image source used by [getClipboardImage].
///
/// Call with `null` to restore the default [pasteboard.Pasteboard.image].
void setTestClipboardImageGetter(ClipboardImageGetter? getter) {
  _clipboardImageGetter = getter ?? () => pasteboard.Pasteboard.image;
}
