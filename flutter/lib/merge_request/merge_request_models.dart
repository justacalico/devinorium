import 'dart:typed_data';

/// Loads CI/CD jobs for a single pipeline.
typedef PipelineJobsLoader =
    Future<List<MergeRequestPipelineJob>> Function(
      MergeRequestPipeline pipeline,
    );

/// Loads the raw bytes of a repository file at a git ref.
///
/// Returns `null` when the file does not exist at that ref or cannot be
/// fetched. Used to render image diffs inline.
typedef MergeRequestFileLoader =
    Future<Uint8List?> Function(String path, String ref);

/// Opens the live log view for a single CI/CD job.
typedef PipelineJobTap = void Function(MergeRequestPipelineJob job);

/// The log output and latest status for a CI/CD job.
class JobLog {
  final MergeRequestPipelineJob job;
  final String trace;

  const JobLog({required this.job, required this.trace});

  factory JobLog.fromJson(Map<String, dynamic> j) => JobLog(
    job: MergeRequestPipelineJob.fromJson(
      j['job'] as Map<String, dynamic>? ?? {},
    ),
    trace: j['trace'] as String? ?? '',
  );
}

/// A state change that can be applied to a merge request.
enum MergeRequestAction {
  close('close'),
  reopen('reopen'),
  merge('merge'),
  mergeWhenPipelineSucceeds('merge_when_pipeline_succeeds'),
  cancelAutoMerge('cancel_auto_merge');

  final String wire;

  const MergeRequestAction(this.wire);
}

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

  /// Image extensions [Image.memory] can decode.
  static const _imageExtensions = {
    '.png',
    '.jpg',
    '.jpeg',
    '.gif',
    '.webp',
    '.bmp',
  };

  /// Whether git could not produce text hunks for this file.
  bool get isBinary => diff
      .split('\n')
      .any(
        (line) =>
            line.startsWith('Binary files') ||
            line.startsWith('GIT binary patch'),
      );

  /// Whether this is a binary change to an image the app can render inline.
  ///
  /// An empty [diff] counts as binary: GitLab elides the diff text for
  /// collapsed or too-large files, and images are always binary.
  bool get isBinaryImage {
    if (!isBinary && diff.trim().isNotEmpty) return false;
    return _imageExtensions.any(
      (ext) =>
          oldPath.toLowerCase().endsWith(ext) ||
          newPath.toLowerCase().endsWith(ext),
    );
  }

  factory MergeRequestChange.fromJson(Map<String, dynamic> j) =>
      MergeRequestChange(
        oldPath: j['old_path'] as String? ?? '',
        newPath: j['new_path'] as String? ?? '',
        diff: j['diff'] as String? ?? '',
        newFile: j['new_file'] as bool? ?? false,
        deletedFile: j['deleted_file'] as bool? ?? false,
        renamedFile: j['renamed_file'] as bool? ?? false,
        generatedFile: j['generated_file'] as bool? ?? false,
      );
}

/// CI/CD pipeline attached to a merge request.
class MergeRequestPipeline {
  final int id;
  final String status;
  final String name;
  final String webUrl;
  final String refName;
  final String createdAt;
  final String updatedAt;

  const MergeRequestPipeline({
    this.id = 0,
    required this.status,
    this.name = '',
    this.webUrl = '',
    this.refName = '',
    this.createdAt = '',
    this.updatedAt = '',
  });

  factory MergeRequestPipeline.fromJson(Map<String, dynamic> j) =>
      MergeRequestPipeline(
        id: (j['id'] as num?)?.toInt() ?? 0,
        status: j['status'] as String? ?? '',
        name: j['name'] as String? ?? '',
        webUrl: j['web_url'] as String? ?? '',
        refName: j['ref_name'] as String? ?? '',
        createdAt: j['created_at'] as String? ?? '',
        updatedAt: j['updated_at'] as String? ?? '',
      );

  bool get isPresent => status.isNotEmpty;

  /// Whether the pipeline has not finished yet, so the merge request can be
  /// set to merge once it succeeds.
  bool get isActive => const {
    'created',
    'waiting_for_resource',
    'preparing',
    'pending',
    'running',
    'scheduled',
  }.contains(status.toLowerCase());
}

/// A single CI/CD job inside a pipeline.
class MergeRequestPipelineJob {
  final int id;
  final String name;
  final String status;
  final String stage;
  final String webUrl;
  final String startedAt;
  final String finishedAt;
  final double duration;

  const MergeRequestPipelineJob({
    this.id = 0,
    this.name = '',
    this.status = '',
    this.stage = '',
    this.webUrl = '',
    this.startedAt = '',
    this.finishedAt = '',
    this.duration = 0,
  });

  factory MergeRequestPipelineJob.fromJson(Map<String, dynamic> j) =>
      MergeRequestPipelineJob(
        id: (j['id'] as num?)?.toInt() ?? 0,
        name: j['name'] as String? ?? '',
        status: j['status'] as String? ?? '',
        stage: j['stage'] as String? ?? '',
        webUrl: j['web_url'] as String? ?? '',
        startedAt: j['started_at'] as String? ?? '',
        finishedAt: j['finished_at'] as String? ?? '',
        duration: (j['duration'] as num?)?.toDouble() ?? 0,
      );

  bool get isPresent => name.isNotEmpty || status.isNotEmpty;

  /// Whether the job is still running or waiting to run, so the log view
  /// should keep polling for updates.
  bool get isLive => const {
    'created',
    'waiting_for_resource',
    'preparing',
    'pending',
    'running',
    'scheduled',
  }.contains(status.toLowerCase());
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
  final bool mergeWhenPipelineSucceeds;
  final MergeRequestAuthor? author;
  final String createdAt;
  final String updatedAt;

  /// The commit sha the diff's "old" side is based on (merge base).
  final String diffBaseSha;

  /// The source branch head sha the diff's "new" side was generated from.
  final String diffHeadSha;

  final List<MergeRequestChange> changes;
  final List<MergeRequestComment> comments;
  final List<MergeRequestPipeline> pipelines;

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
    this.mergeWhenPipelineSucceeds = false,
    this.author,
    this.createdAt = '',
    this.updatedAt = '',
    this.diffBaseSha = '',
    this.diffHeadSha = '',
    this.changes = const [],
    this.comments = const [],
    this.pipelines = const [],
  });

  bool get isOpen => state == 'opened' || state == 'open';

  bool get isClosed => state == 'closed';

  bool get isMerged => state == 'merged';

  /// Whether merging is allowed right now. Drafts and conflicting merge
  /// requests are rejected by GitLab, so the buttons stay disabled.
  bool get canMerge => isOpen && !draft && !hasConflicts;

  String get branches => '$sourceBranch → $targetBranch';
}
