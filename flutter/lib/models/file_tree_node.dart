import 'files.dart';

/// A row that the [FilesPanel] renders while walking a [FileTreeNode].
class FileTreeRow {
  final FileTreeNode node;
  final int indent;
  final FileTreeRowKind kind;

  const FileTreeRow.node(this.node, this.indent) : kind = FileTreeRowKind.node;

  const FileTreeRow.loading(this.node, this.indent)
    : kind = FileTreeRowKind.loading;

  const FileTreeRow.error(this.node, this.indent)
    : kind = FileTreeRowKind.error;

  const FileTreeRow.loadMore(this.node, this.indent)
    : kind = FileTreeRowKind.loadMore;

  const FileTreeRow.empty(this.node, this.indent)
    : kind = FileTreeRowKind.empty;
}

enum FileTreeRowKind { node, loading, error, loadMore, empty }

/// A node in the files panel tree.
///
/// Each node knows its [path] (segments from the root to its parent),
/// the underlying [entry], and whether it is expanded/loaded.
class FileTreeNode {
  final List<String> path;
  final DirEntry entry;
  bool isExpanded;
  bool isLoading;
  bool isLoadingMore;
  List<FileTreeNode> children;
  bool hasMore;
  int offset;
  String error;

  FileTreeNode({
    required this.path,
    required this.entry,
    this.isExpanded = false,
    this.isLoading = false,
    this.isLoadingMore = false,
    List<FileTreeNode>? children,
    this.hasMore = false,
    this.offset = 0,
    this.error = '',
  }) : children = children ?? [];

  String get name => entry.name;

  List<String> get fullPath {
    if (entry.name.isEmpty) return path;
    return [...path, entry.name];
  }

  String get fullPathString => fullPath.join('/');

  bool get isRoot => entry.name.isEmpty;

  static FileTreeNode root() => FileTreeNode(
    path: const [],
    entry: DirEntry(name: '', isDir: true, size: 0),
    hasMore: true,
  );
}

/// Flattens [node] into a list of [FileTreeRow]s suitable for a
/// [ListView.builder].
List<FileTreeRow> buildFileTreeRows(FileTreeNode node, {int indent = 0}) {
  if (node.isRoot && node.isLoading) {
    return [FileTreeRow.loading(node, indent)];
  }
  final rows = <FileTreeRow>[];
  for (final child in node.children) {
    rows.add(FileTreeRow.node(child, indent));
    if (child.isExpanded) {
      if (child.isLoading) {
        rows.add(FileTreeRow.loading(child, indent + 1));
      } else if (child.error.isNotEmpty) {
        rows.add(FileTreeRow.error(child, indent + 1));
      } else if (child.children.isEmpty && !child.hasMore) {
        rows.add(FileTreeRow.empty(child, indent + 1));
      } else {
        rows.addAll(buildFileTreeRows(child, indent: indent + 1));
      }
    }
  }
  if ((node.hasMore || node.isLoadingMore) && !node.isLoading) {
    rows.add(FileTreeRow.loadMore(node, indent));
  }
  return rows;
}
