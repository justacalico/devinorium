import 'messages.dart';

class FileContent {
  final String path;
  final String mime;
  final int size;
  final String base64;
  final String? text;
  final FileDiff? diff;

  FileContent({
    required this.path,
    required this.mime,
    required this.size,
    required this.base64,
    this.text,
    this.diff,
  });

  factory FileContent.fromJson(Map<String, dynamic> j) {
    final diff = j['diff'] == null
        ? null
        : FileDiff.fromJson(j['diff'] as Map<String, dynamic>);
    return FileContent(
      path: j['path'] as String? ?? '',
      mime: j['mime'] as String? ?? 'application/octet-stream',
      size: (j['size'] as num?)?.toInt() ?? 0,
      base64: j['base64'] as String? ?? '',
      text: (j['text'] as String?) ?? diff?.newText,
      diff: diff,
    );
  }
}

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
