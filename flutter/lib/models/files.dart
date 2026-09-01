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
