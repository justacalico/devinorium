class Attachment {
  final String filename;
  final int size;

  Attachment({required this.filename, required this.size});

  factory Attachment.fromJson(Map<String, dynamic> j) => Attachment(
    filename: j['filename'] as String,
    size: (j['size'] as num).toInt(),
  );

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! Attachment) return false;
    return filename == other.filename && size == other.size;
  }

  @override
  int get hashCode => Object.hash(filename, size);
}
