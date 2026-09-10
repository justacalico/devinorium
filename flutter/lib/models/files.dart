import 'messages.dart';

class FileContent {
  final String path;
  final String mime;
  final int size;
  final String base64;
  final String? text;
  final FileDiff? diff;
  final String sha256;
  final DateTime? lastModified;

  FileContent({
    required this.path,
    required this.mime,
    required this.size,
    required this.base64,
    this.text,
    this.diff,
    this.sha256 = '',
    this.lastModified,
  });

  factory FileContent.fromJson(Map<String, dynamic> j) {
    final diff = j['diff'] == null
        ? null
        : FileDiff.fromJson(j['diff'] as Map<String, dynamic>);
    final lastModifiedRaw = j['last_modified'] as String?;
    return FileContent(
      path: j['path'] as String? ?? '',
      mime: j['mime'] as String? ?? 'application/octet-stream',
      size: (j['size'] as num?)?.toInt() ?? 0,
      base64: j['base64'] as String? ?? '',
      text: (j['text'] as String?) ?? diff?.newText,
      diff: diff,
      sha256: j['sha256'] as String? ?? '',
      lastModified:
          lastModifiedRaw == null ? null : DateTime.tryParse(lastModifiedRaw),
    );
  }

  FileContent copyWith({
    String? path,
    String? mime,
    int? size,
    String? base64,
    String? text,
    FileDiff? diff,
    String? sha256,
    DateTime? lastModified,
  }) =>
      FileContent(
        path: path ?? this.path,
        mime: mime ?? this.mime,
        size: size ?? this.size,
        base64: base64 ?? this.base64,
        text: text ?? this.text,
        diff: diff ?? this.diff,
        sha256: sha256 ?? this.sha256,
        lastModified: lastModified ?? this.lastModified,
      );

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is FileContent &&
        other.path == path &&
        other.mime == mime &&
        other.size == size &&
        other.base64 == base64 &&
        other.text == text &&
        other.diff == diff &&
        other.sha256 == sha256 &&
        other.lastModified == lastModified;
  }

  @override
  int get hashCode => Object.hash(
    path,
    mime,
    size,
    base64,
    text,
    diff,
    sha256,
    lastModified,
  );
}

/// Exception thrown by [ApiService.writeFile] when the file has changed on disk.
class FileConflictException implements Exception {
  final FileContent current;
  FileConflictException(this.current);

  @override
  String toString() => 'file changed on disk';
}

/// A file or folder the user dragged from the files panel into the composer
/// as a prompt reference. The path is relative to the project root and lives
/// on the backend machine, so nothing is uploaded.
typedef PathRef = ({String path, bool isDir});

class DirEntry {
  final String name;
  final bool isDir;
  final int size;
  final String? gitStatus;

  DirEntry({
    required this.name,
    required this.isDir,
    required this.size,
    this.gitStatus,
  });

  factory DirEntry.fromJson(Map<String, dynamic> j) => DirEntry(
    name: j['name'] as String,
    isDir: (j['is_dir'] as bool?) ?? false,
    size: ((j['size'] as num?) ?? 0).toInt(),
    gitStatus: j['git_status'] as String?,
  );
}
