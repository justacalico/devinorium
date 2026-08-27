class DirEntry {
  final String name;
  final bool isDir;
  final int size;

  DirEntry({required this.name, required this.isDir, required this.size});

  factory DirEntry.fromJson(Map<String, dynamic> j) => DirEntry(
    name: j['name'] as String,
    isDir: (j['is_dir'] as bool?) ?? false,
    size: (j['size'] as num).toInt(),
  );
}
