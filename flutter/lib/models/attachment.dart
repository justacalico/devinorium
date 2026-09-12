class Attachment {
  final String filename;
  final int size;

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
    this.isPathRef = false,
    this.isThreadRef = false,
    this.isDir = false,
  });

  factory Attachment.fromJson(Map<String, dynamic> j) => Attachment(
    filename: j['filename'] as String,
    size: (j['size'] as num).toInt(),
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
        isPathRef == other.isPathRef &&
        isThreadRef == other.isThreadRef &&
        isDir == other.isDir;
  }

  @override
  int get hashCode => Object.hash(filename, size, isPathRef, isThreadRef, isDir);
}
