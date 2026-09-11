import 'package:flutter/foundation.dart' show listEquals;
import 'package:path/path.dart' as p;

import 'git.dart';
import 'messages.dart';

class _Unset {
  const _Unset();
}

const Object _unset = _Unset();

class Project {
  final int id;
  final String name;
  final String path;
  final int position;
  final bool pinned;
  final bool isRepo;
  final String gitBranch;
  final String projectType;
  final String createdAt;
  final String updatedAt;

  Project({
    required this.id,
    required this.name,
    required this.path,
    this.position = 0,
    this.pinned = false,
    this.isRepo = false,
    this.gitBranch = '',
    this.projectType = 'generic',
    required this.createdAt,
    required this.updatedAt,
  });

  factory Project.fromJson(Map<String, dynamic> j) => Project(
    id: (j['id'] as num).toInt(),
    name: j['name'] as String,
    path: j['path'] as String,
    position: (j['position'] as num?)?.toInt() ?? 0,
    pinned: j['pinned'] as bool? ?? false,
    isRepo: j['is_repo'] as bool? ?? false,
    gitBranch: j['branch'] as String? ?? '',
    projectType: j['project_type'] as String? ?? 'generic',
    createdAt: j['created_at'] as String? ?? '',
    updatedAt: j['updated_at'] as String? ?? '',
  );

  Project copyWith({
    int? id,
    String? name,
    String? path,
    int? position,
    bool? pinned,
    bool? isRepo,
    String? gitBranch,
    String? projectType,
    String? createdAt,
    String? updatedAt,
  }) => Project(
    id: id ?? this.id,
    name: name ?? this.name,
    path: path ?? this.path,
    position: position ?? this.position,
    pinned: pinned ?? this.pinned,
    isRepo: isRepo ?? this.isRepo,
    gitBranch: gitBranch ?? this.gitBranch,
    projectType: projectType ?? this.projectType,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! Project) return false;
    return id == other.id &&
        name == other.name &&
        path == other.path &&
        position == other.position &&
        pinned == other.pinned &&
        isRepo == other.isRepo &&
        gitBranch == other.gitBranch &&
        projectType == other.projectType &&
        createdAt == other.createdAt &&
        updatedAt == other.updatedAt;
  }

  @override
  int get hashCode => Object.hash(
    id,
    name,
    path,
    position,
    pinned,
    isRepo,
    gitBranch,
    projectType,
    createdAt,
    updatedAt,
  );
}

LinkedMergeRequestRef? _parseLinkedMr(Object? raw) {
  if (raw is! Map<String, dynamic>) return null;
  try {
    return LinkedMergeRequestRef.fromJson(raw);
  } catch (_) {
    return null;
  }
}

class Thread {
  final String id;
  final String title;
  final int? threadGroupId;
  final int projectId;
  final String? devinSessionId;
  final String providerId;
  final String model;
  final String permissionMode;
  final String reasoningEffort;
  final String? permissions;
  final String? branch;
  final String? worktreePath;
  final String envMode;
  final bool pinned;
  final String createdAt;
  final String updatedAt;
  final LinkedMergeRequestRef? linkedMr;

  Thread({
    required this.id,
    required this.title,
    this.threadGroupId,
    required this.projectId,
    this.devinSessionId,
    this.providerId = 'devin-cli',
    required this.model,
    required this.permissionMode,
    this.reasoningEffort = '',
    this.permissions,
    this.branch,
    this.worktreePath,
    this.envMode = 'local',
    this.pinned = false,
    required this.createdAt,
    required this.updatedAt,
    this.linkedMr,
  });

  factory Thread.fromJson(Map<String, dynamic> j) => Thread(
    id: j['id'] as String,
    title: j['title'] as String,
    threadGroupId: j['thread_group_id'] as int?,
    projectId: (j['project_id'] as num?)?.toInt() ?? 0,
    devinSessionId: j['devin_session_id'] as String?,
    providerId: j['provider_id'] as String? ?? 'devin-cli',
    model: j['model'] as String? ?? '',
    permissionMode: j['permission_mode'] as String? ?? 'normal',
    reasoningEffort: j['reasoning_effort'] as String? ?? '',
    permissions: j['permissions'] as String?,
    branch: j['branch'] as String?,
    worktreePath: j['worktree_path'] as String?,
    envMode: j['env_mode'] as String? ?? 'local',
    pinned: j['pinned'] as bool? ?? false,
    createdAt: j['created_at'] as String? ?? '',
    updatedAt: j['updated_at'] as String? ?? '',
    linkedMr: _parseLinkedMr(j['linked_mr']),
  );

  /// A short display name for the thread's active worktree.
  ///
  /// Returns the last segment of [worktreePath] when one is set, otherwise
  /// falls back to [branch] for worktree-mode threads that have not yet been
  /// associated with a path.
  String? get worktreeName {
    final wt = worktreePath;
    if (wt != null && wt.isNotEmpty) {
      final name = _worktreeBasename(wt);
      if (name.isNotEmpty && !_isRootPath(name, wt)) return name;
    }
    final b = branch;
    if (envMode == 'worktree' && b != null && b.isNotEmpty) return b;
    return null;
  }

  Thread copyWith({
    String? title,
    String? updatedAt,
    bool? pinned,
    String? envMode,
    LinkedMergeRequestRef? linkedMr,
    Object? linkedMrOrNull = const _Unset(),
    Object? branch = const _Unset(),
    Object? worktreePath = const _Unset(),
  }) => Thread(
    id: id,
    title: title ?? this.title,
    threadGroupId: threadGroupId,
    projectId: projectId,
    devinSessionId: devinSessionId,
    providerId: providerId,
    model: model,
    permissionMode: permissionMode,
    reasoningEffort: reasoningEffort,
    permissions: permissions,
    branch: branch is _Unset ? this.branch : (branch as String?),
    worktreePath:
        worktreePath is _Unset ? this.worktreePath : (worktreePath as String?),
    envMode: envMode ?? this.envMode,
    pinned: pinned ?? this.pinned,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    linkedMr: linkedMrOrNull is _Unset
        ? (linkedMr ?? this.linkedMr)
        : (linkedMrOrNull as LinkedMergeRequestRef?),
  );

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! Thread) return false;
    return id == other.id &&
        title == other.title &&
        threadGroupId == other.threadGroupId &&
        projectId == other.projectId &&
        devinSessionId == other.devinSessionId &&
        providerId == other.providerId &&
        model == other.model &&
        permissionMode == other.permissionMode &&
        reasoningEffort == other.reasoningEffort &&
        permissions == other.permissions &&
        branch == other.branch &&
        worktreePath == other.worktreePath &&
        envMode == other.envMode &&
        pinned == other.pinned &&
        createdAt == other.createdAt &&
        updatedAt == other.updatedAt &&
        linkedMr == other.linkedMr;
  }

  @override
  int get hashCode => Object.hash(
    id,
    title,
    threadGroupId,
    projectId,
    devinSessionId,
    providerId,
    model,
    permissionMode,
    reasoningEffort,
    permissions,
    branch,
    worktreePath,
    envMode,
    pinned,
    createdAt,
    updatedAt,
    linkedMr,
  );
}

/// A thread dropped into the composer so its history is sent along as
/// context for the next message.
class ThreadReference {
  final String id;
  final String title;

  const ThreadReference({required this.id, required this.title});

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! ThreadReference) return false;
    return id == other.id && title == other.title;
  }

  @override
  int get hashCode => Object.hash(id, title);
}

class ThreadGroup {
  final int id;
  final String name;
  final int position;
  final String createdAt;

  ThreadGroup({
    required this.id,
    required this.name,
    required this.position,
    required this.createdAt,
  });

  factory ThreadGroup.fromJson(Map<String, dynamic> j) => ThreadGroup(
    id: (j['id'] as num).toInt(),
    name: j['name'] as String,
    position: (j['position'] as num).toInt(),
    createdAt: j['created_at'] as String? ?? '',
  );
}

class PlanStep {
  final String step;
  final String status;

  PlanStep({required this.step, this.status = 'pending'});

  factory PlanStep.fromJson(Map<String, dynamic> j) => PlanStep(
    step: j['step'] as String? ?? '',
    status: j['status'] as String? ?? 'pending',
  );

  bool get isPending => status == 'pending';
  bool get isInProgress => status == 'in_progress';
  bool get isCompleted => status == 'completed';

  PlanStep copyWith({String? status}) =>
      PlanStep(step: step, status: status ?? this.status);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! PlanStep) return false;
    return step == other.step && status == other.status;
  }

  @override
  int get hashCode => Object.hash(step, status);
}

class Plan {
  final String? explanation;
  final List<PlanStep> steps;

  Plan({this.explanation, this.steps = const []});

  factory Plan.fromJson(Map<String, dynamic> j) => Plan(
    explanation: j['explanation'] as String?,
    steps: ((j['steps'] as List<dynamic>?) ?? [])
        .map((s) => PlanStep.fromJson(s as Map<String, dynamic>))
        .toList(),
  );

  bool get isEmpty => steps.isEmpty;

  int get progressPercent {
    if (steps.isEmpty) return 0;
    final completed = steps.where((s) => s.isCompleted).length;
    final percent = ((completed / steps.length) * 100).round();
    return percent.clamp(0, 100);
  }

  Plan copyWith({String? explanation, List<PlanStep>? steps}) => Plan(
    explanation: explanation ?? this.explanation,
    steps: steps ?? this.steps,
  );

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! Plan) return false;
    return explanation == other.explanation && listEquals(steps, other.steps);
  }

  @override
  int get hashCode {
    var h = Object.hash(explanation, steps.length);
    for (final s in steps) {
      h = Object.hash(h, s);
    }
    return h;
  }
}

class ThreadDetail {
  final Thread thread;
  List<Message> messages;
  int totalMessages;
  Plan? plan;
  String? beforeCursor;
  bool? hasMore;
  int? turnLimit;
  int? rawCount;

  ThreadDetail({
    required this.thread,
    this.messages = const [],
    this.totalMessages = 0,
    this.plan,
    this.beforeCursor,
    this.hasMore,
    this.turnLimit,
    this.rawCount,
  });

  factory ThreadDetail.fromJson(Map<String, dynamic> j) => ThreadDetail(
    thread: Thread.fromJson(j['thread'] as Map<String, dynamic>),
    messages: ((j['messages'] as List<dynamic>?) ?? [])
        .map((m) => Message.fromJson(m as Map<String, dynamic>))
        .toList(),
    totalMessages:
        (j['total_messages'] as num?)?.toInt() ??
        ((j['messages'] as List<dynamic>?) ?? []).length,
    plan: j['plan'] == null
        ? null
        : Plan.fromJson(j['plan'] as Map<String, dynamic>),
    beforeCursor: j['before_cursor'] as String?,
    hasMore: j['has_more'] as bool?,
    turnLimit: (j['turn_limit'] as num?)?.toInt(),
    rawCount: (j['raw_count'] as num?)?.toInt(),
  );

  ThreadDetail copyWith({
    Thread? thread,
    List<Message>? messages,
    int? totalMessages,
    Plan? plan,
    bool clearPlan = false,
    Object? beforeCursor = _unset,
    Object? hasMore = _unset,
    Object? turnLimit = _unset,
    Object? rawCount = _unset,
  }) => ThreadDetail(
    thread: thread ?? this.thread,
    messages: messages ?? this.messages,
    totalMessages: totalMessages ?? this.totalMessages,
    plan: clearPlan ? null : (plan ?? this.plan),
    beforeCursor: beforeCursor == _unset
        ? this.beforeCursor
        : beforeCursor as String?,
    hasMore: hasMore == _unset ? this.hasMore : hasMore as bool?,
    turnLimit: turnLimit == _unset ? this.turnLimit : turnLimit as int?,
    rawCount: rawCount == _unset ? this.rawCount : rawCount as int?,
  );

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! ThreadDetail) return false;
    return thread == other.thread &&
        listEquals(messages, other.messages) &&
        totalMessages == other.totalMessages &&
        plan == other.plan &&
        beforeCursor == other.beforeCursor &&
        hasMore == other.hasMore &&
        turnLimit == other.turnLimit &&
        rawCount == other.rawCount;
  }

  @override
  int get hashCode => Object.hash(
    thread,
    Object.hashAll(messages),
    totalMessages,
    plan,
    beforeCursor,
    hasMore,
    turnLimit,
    rawCount,
  );
}

String _worktreeBasename(String path) {
  if (path.contains('\\')) {
    return p.Context(style: p.Style.windows).basename(path);
  }
  return p.Context(style: p.Style.posix).basename(path);
}

bool _isRootPath(String basename, String path) {
  if (basename.isEmpty) return true;
  if (basename == path) {
    // A path that contains separators but has no trailing filename is a root
    // such as '/' or 'C:\'.
    return path.contains('/') || path.contains('\\');
  }
  return false;
}
