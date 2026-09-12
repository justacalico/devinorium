import 'dart:typed_data';

/// Whether [mime] names an image `Image.memory` can decode inline. Kept to a
/// whitelist: `image/*` also covers svg, heic, avif and friends that the
/// codec cannot rasterize.
bool isImageMime(String mime) => const {
  'image/png',
  'image/jpeg',
  'image/gif',
  'image/webp',
  'image/bmp',
  'image/x-ms-bmp',
}.contains(mime.toLowerCase());

class Attachment {
  final String filename;
  final int size;
  final String mime;

  /// Position in the message's uploaded-file list, used to fetch the stored
  /// blob from the backend. Null for path/thread refs and for attachments
  /// persisted before blobs existed.
  final int? index;

  /// Bytes held in memory for optimistic (not yet acknowledged) messages.
  /// Not parsed from JSON; excluded from equality because it is transport
  /// data, not identity.
  final Uint8List? bytes;

  /// True when this entry is a reference to a path on the backend machine
  /// (dragged in from the files panel) rather than an uploaded file.
  final bool isPathRef;

  /// True when this entry references another thread (dragged in from the
  /// sidebar) whose history was sent as context.
  final bool isThreadRef;

  /// For path refs: whether the referenced path is a directory.
  final bool isDir;

  Attachment({
    required this.filename,
    required this.size,
    this.mime = '',
    this.index,
    this.bytes,
    this.isPathRef = false,
    this.isThreadRef = false,
    this.isDir = false,
  });

  bool get isImage => isImageMime(mime);

  Attachment withBytes(Uint8List data) => Attachment(
    filename: filename,
    size: size,
    mime: mime,
    index: index,
    bytes: data,
    isPathRef: isPathRef,
    isThreadRef: isThreadRef,
    isDir: isDir,
  );

  factory Attachment.fromJson(Map<String, dynamic> j) => Attachment(
    filename: j['filename'] as String,
    size: (j['size'] as num).toInt(),
    mime: j['mime'] as String? ?? '',
    index: (j['index'] as num?)?.toInt(),
    isPathRef: j['kind'] == 'path',
    isThreadRef: j['kind'] == 'thread',
    isDir: j['is_dir'] as bool? ?? false,
  );

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! Attachment) return false;
    return filename == other.filename &&
        size == other.size &&
        mime == other.mime &&
        index == other.index &&
        isPathRef == other.isPathRef &&
        isThreadRef == other.isThreadRef &&
        isDir == other.isDir;
  }

  @override
  int get hashCode =>
      Object.hash(filename, size, mime, index, isPathRef, isThreadRef, isDir);
}
