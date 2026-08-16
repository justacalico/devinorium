import 'dart:typed_data';

/// Result of trying to attach a path from the clipboard.
sealed class PathAttachmentResult {
  const PathAttachmentResult();
}

/// The clipboard text was a valid file and has been read.
final class PathAttached extends PathAttachmentResult {
  final String filename;
  final String mime;
  final Uint8List bytes;

  const PathAttached(this.filename, this.mime, this.bytes);
}

/// The clipboard text was a file path but the file is too large.
final class PathTooLarge extends PathAttachmentResult {
  final String filename;
  final int size;

  const PathTooLarge(this.filename, this.size);
}

/// The clipboard text was not a usable file path; fall back to normal paste.
final class PathFallback extends PathAttachmentResult {
  const PathFallback();
}
