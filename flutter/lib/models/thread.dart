import 'package:flutter/foundation.dart' show listEquals;

import 'messages.dart';

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

class Thread {
  final String id;
  final String title;
  final int? threadGroupId;
  final int projectId;
  final String? devinSessionId;
  final String model;
  final String permissionMode;
  final String? permissions;
  final String? branch;
  final String? worktreePath;
  final bool pinned;
  final String createdAt;
  final String updatedAt;

  Thread({
    required this.id,
    required this.title,
    this.threadGroupId,
    required this.projectId,
    this.devinSessionId,
    required this.model,
    required this.permissionMode,
    this.permissions,
    this.branch,
    this.worktreePath,
    this.pinned = false,
    required this.createdAt,
    required this.updatedAt,
  });

  factory Thread.fromJson(Map<String, dynamic> j) => Thread(
    id: j['id'] as String,
    title: j['title'] as String,
    threadGroupId: j['thread_group_id'] as int?,
    projectId: (j['project_id'] as num?)?.toInt() ?? 0,
    devinSessionId: j['devin_session_id'] as String?,
    model: j['model'] as String? ?? '',
    permissionMode: j['permission_mode'] as String? ?? 'normal',
    permissions: j['permissions'] as String?,
    branch: j['branch'] as String?,
    worktreePath: j['worktree_path'] as String?,
    pinned: j['pinned'] as bool? ?? false,
    createdAt: j['created_at'] as String? ?? '',
    updatedAt: j['updated_at'] as String? ?? '',
  );

  Thread copyWith({String? title, String? updatedAt, bool? pinned}) => Thread(
    id: id,
    title: title ?? this.title,
    threadGroupId: threadGroupId,
    projectId: projectId,
    devinSessionId: devinSessionId,
    model: model,
    permissionMode: permissionMode,
    permissions: permissions,
    branch: branch,
    worktreePath: worktreePath,
    pinned: pinned ?? this.pinned,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
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
        model == other.model &&
        permissionMode == other.permissionMode &&
        permissions == other.permissions &&
        branch == other.branch &&
        worktreePath == other.worktreePath &&
        pinned == other.pinned &&
        createdAt == other.createdAt &&
        updatedAt == other.updatedAt;
  }

  @override
  int get hashCode => Object.hash(
    id,
    title,
    threadGroupId,
    projectId,
    devinSessionId,
    model,
    permissionMode,
    permissions,
    branch,
    worktreePath,
    pinned,
    createdAt,
    updatedAt,
  );
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

  ThreadDetail({
    required this.thread,
    this.messages = const [],
    this.totalMessages = 0,
    this.plan,
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
  );

  ThreadDetail copyWith({
    Thread? thread,
    List<Message>? messages,
    int? totalMessages,
    Plan? plan,
    bool clearPlan = false,
  }) => ThreadDetail(
    thread: thread ?? this.thread,
    messages: messages ?? this.messages,
    totalMessages: totalMessages ?? this.totalMessages,
    plan: clearPlan ? null : (plan ?? this.plan),
  );

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! ThreadDetail) return false;
    return thread == other.thread &&
        totalMessages == other.totalMessages &&
        plan == other.plan;
  }

  @override
  int get hashCode => Object.hash(thread, totalMessages, plan);
}
