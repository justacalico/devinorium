/// Author of a merge request or comment.
class MergeRequestAuthor {
  final String name;
  final String username;
  final String? avatarUrl;

  const MergeRequestAuthor({
    required this.name,
    required this.username,
    this.avatarUrl,
  });

  factory MergeRequestAuthor.fromJson(Map<String, dynamic> j) {
    final username = j['username'] as String? ?? '';
    return MergeRequestAuthor(
      name: j['name'] as String? ?? username,
      username: username,
      avatarUrl: j['avatar_url'] as String?,
    );
  }
}

/// A single changed file in a merge request.
class MergeRequestChange {
  final String oldPath;
  final String newPath;
  final String diff;
  final bool newFile;
  final bool deletedFile;
  final bool renamedFile;
  final bool generatedFile;

  const MergeRequestChange({
    required this.oldPath,
    required this.newPath,
    required this.diff,
    this.newFile = false,
    this.deletedFile = false,
    this.renamedFile = false,
    this.generatedFile = false,
  });

  String get displayPath => newPath.isNotEmpty ? newPath : oldPath;

  factory MergeRequestChange.fromJson(Map<String, dynamic> j) => MergeRequestChange(
        oldPath: j['old_path'] as String? ?? '',
        newPath: j['new_path'] as String? ?? '',
        diff: j['diff'] as String? ?? '',
        newFile: j['new_file'] as bool? ?? false,
        deletedFile: j['deleted_file'] as bool? ?? false,
        renamedFile: j['renamed_file'] as bool? ?? false,
        generatedFile: j['generated_file'] as bool? ?? false,
      );
}

/// A comment or note on a merge request.
class MergeRequestComment {
  final MergeRequestAuthor? author;
  final String body;
  final String createdAt;
  final bool system;
  final bool resolved;

  const MergeRequestComment({
    this.author,
    required this.body,
    this.createdAt = '',
    this.system = false,
    this.resolved = false,
  });

  factory MergeRequestComment.fromJson(Map<String, dynamic> j) {
    final authorJson = j['author'];
    return MergeRequestComment(
      author: authorJson is Map<String, dynamic>
          ? MergeRequestAuthor.fromJson(authorJson)
          : null,
      body: j['body'] as String? ?? '',
      createdAt: j['created_at'] as String? ?? '',
      system: j['system'] as bool? ?? false,
      resolved: j['resolved'] as bool? ?? false,
    );
  }
}

/// Fully loaded merge request details.
class MergeRequestDetail {
  final String title;
  final String description;
  final String state;
  final String sourceBranch;
  final String targetBranch;
  final int iid;
  final String webUrl;
  final bool draft;
  final bool hasConflicts;
  final MergeRequestAuthor? author;
  final String createdAt;
  final String updatedAt;
  final List<MergeRequestChange> changes;
  final List<MergeRequestComment> comments;

  const MergeRequestDetail({
    required this.title,
    this.description = '',
    this.state = '',
    required this.sourceBranch,
    required this.targetBranch,
    required this.iid,
    required this.webUrl,
    this.draft = false,
    this.hasConflicts = false,
    this.author,
    this.createdAt = '',
    this.updatedAt = '',
    this.changes = const [],
    this.comments = const [],
  });

  bool get isOpen => state == 'opened' || state == 'open';

  String get branches => '$sourceBranch → $targetBranch';
}
