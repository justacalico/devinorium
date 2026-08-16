export 'path_attachment_types.dart';

import 'path_attachment_types.dart';
import 'path_attachment_io.dart'
    if (dart.library.js_interop) 'path_attachment_web.dart' as impl;

/// Checks whether [text] is a path to a readable file and, if so, reads it.
///
/// Returns [PathAttached] with the file bytes, [PathTooLarge] if the file
/// exceeds 8 MB, or [PathFallback] if the text is not a usable file path.
Future<PathAttachmentResult> maybeAttachPath(String text) => impl.attachPath(text);
