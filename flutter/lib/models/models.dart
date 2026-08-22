import 'dart:convert';

bool _listEquals<T>(List<T>? a, List<T>? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null || a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

class User {
  final int id;
  final String username;
  final String role;
  final bool totpEnabled;
  final bool isOwner;
  final bool disabled;
  final String createdAt;
  final String providerId;
  final String providerCommand;

  User({
    required this.id,
    required this.username,
    required this.role,
    required this.totpEnabled,
    this.isOwner = false,
    this.disabled = false,
    this.createdAt = '',
    required this.providerId,
    required this.providerCommand,
  });

  factory User.fromJson(Map<String, dynamic> j) => User(
        id: (j['id'] as num).toInt(),
        username: j['username'] as String,
        role: j['role'] as String,
        totpEnabled: (j['totp_enabled'] as bool?) ?? false,
        isOwner: (j['is_owner'] as bool?) ?? false,
        disabled: (j['disabled'] as bool?) ?? false,
        createdAt: j['created_at'] as String? ?? '',
        providerId: j['provider_id'] as String? ?? 'devin-cli',
        providerCommand: (j['provider_command'] as String? ?? '').trim().isEmpty
            ? 'devin'
            : j['provider_command'] as String,
      );

  User copyWith({
    String? providerId,
    String? providerCommand,
    bool? isOwner,
    bool? disabled,
    String? createdAt,
  }) =>
      User(
        id: id,
        username: username,
        role: role,
        totpEnabled: totpEnabled,
        isOwner: isOwner ?? this.isOwner,
        disabled: disabled ?? this.disabled,
        createdAt: createdAt ?? this.createdAt,
        providerId: providerId ?? this.providerId,
        providerCommand: providerCommand ?? this.providerCommand,
      );
}

class LoginResponse {
  final bool ok;
  final bool totpRequired;
  final String username;
  final String token;

  LoginResponse({
    required this.ok,
    required this.totpRequired,
    required this.username,
    this.token = '',
  });

  factory LoginResponse.fromJson(Map<String, dynamic> j) => LoginResponse(
        ok: (j['ok'] as bool?) ?? false,
        totpRequired: (j['totp_required'] as bool?) ?? false,
        username: j['username'] as String? ?? '',
        token: j['token'] as String? ?? '',
      );
}

class Device {
  final String deviceId;
  final String tokenPrefix;
  final String? name;
  final String createdAt;
  final String lastSeenAt;
  final String expiresAt;
  final bool isCurrent;

  Device({
    required this.deviceId,
    required this.tokenPrefix,
    this.name,
    required this.createdAt,
    required this.lastSeenAt,
    required this.expiresAt,
    required this.isCurrent,
  });

  factory Device.fromJson(Map<String, dynamic> j) => Device(
        deviceId: j['device_id'] as String? ?? '',
        tokenPrefix: j['token_prefix'] as String? ?? '',
        name: j['name'] as String?,
        createdAt: j['created_at'] as String? ?? '',
        lastSeenAt: j['last_seen_at'] as String? ?? '',
        expiresAt: j['expires_at'] as String? ?? '',
        isCurrent: (j['is_current'] as bool?) ?? false,
      );
}

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

class Message {
  final int? id;
  final String role;
  final String content;
  final String? thinking;
  final List<Attachment>? attachments;
  final List<MessagePart>? parts;

  Message({
    this.id,
    required this.role,
    required this.content,
    this.thinking,
    this.attachments,
    this.parts,
  });

  factory Message.fromJson(Map<String, dynamic> j) => Message(
        id: (j['id'] as num?)?.toInt(),
        role: j['role'] as String,
        content: j['content'] as String? ?? '',
        thinking: j['thinking'] as String?,
        attachments: (j['attachments'] as List<dynamic>?)
            ?.map((a) => Attachment.fromJson(a as Map<String, dynamic>))
            .toList(),
        parts: (j['parts'] as List<dynamic>?)
            ?.map((p) => MessagePart.fromJson(p as Map<String, dynamic>))
            .toList(),
      );

  List<MessagePart> get allParts {
    if (parts != null && parts!.isNotEmpty) return parts!;
    final list = <MessagePart>[MessagePart.text(content: content)];
    if (thinking != null && thinking!.isNotEmpty) {
      list.add(MessagePart.thinking(content: thinking!));
    }
    return list;
  }

  Message copyWith({
    int? id,
    String? content,
    List<MessagePart>? parts,
  }) =>
      Message(
        id: id ?? this.id,
        role: role,
        content: content ?? this.content,
        thinking: thinking,
        attachments: attachments,
        parts: parts ?? this.parts,
      );

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! Message) return false;
    return id == other.id &&
        role == other.role &&
        content == other.content &&
        thinking == other.thinking &&
        _listEquals(attachments, other.attachments) &&
        _listEquals(parts, other.parts);
  }

  @override
  int get hashCode {
    var h = Object.hash(id, role, content, thinking);
    for (final a in attachments ?? const <Attachment>[]) {
      h = Object.hash(h, a);
    }
    for (final p in parts ?? const <MessagePart>[]) {
      h = Object.hash(h, p);
    }
    return h;
  }
}

class FileDiff {
  final String path;
  final String? oldText;
  final String newText;

  const FileDiff({
    required this.path,
    this.oldText,
    required this.newText,
  });

  factory FileDiff.fromJson(Map<String, dynamic> j) => FileDiff(
        path: j['path'] as String? ?? '',
        oldText: j['old_text'] as String?,
        newText: j['new_text'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
        'path': path,
        if (oldText != null) 'old_text': oldText,
        'new_text': newText,
      };

  FileDiff copyWith({String? path, String? oldText, String? newText}) =>
      FileDiff(
        path: path ?? this.path,
        oldText: oldText ?? this.oldText,
        newText: newText ?? this.newText,
      );

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! FileDiff) return false;
    return path == other.path &&
        oldText == other.oldText &&
        newText == other.newText;
  }

  @override
  int get hashCode => Object.hash(path, oldText, newText);
}

class ToolCallData {
  final String id;
  final String title;
  final String kind;
  final String status;
  final String? command;
  final String? output;
  final String? outputPreview;
  final List<String> changedFiles;
  final List<FileDiff> diffs;

  ToolCallData({
    required this.id,
    required this.title,
    required this.kind,
    required this.status,
    this.command,
    this.output,
    this.outputPreview,
    this.changedFiles = const [],
    this.diffs = const [],
  });

  factory ToolCallData.fromJson(Map<String, dynamic> j) => ToolCallData(
        id: j['id'] as String,
        title: j['title'] as String,
        kind: j['kind'] as String,
        status: j['status'] as String,
        command: j['command'] as String?,
        output: j['output'] as String?,
        outputPreview: j['output_preview'] as String?,
        changedFiles: (j['changed_files'] as List<dynamic>?)
                ?.map((e) => e as String)
                .toList() ??
            const [],
        diffs: (j['diffs'] as List<dynamic>?)
                ?.map((e) => FileDiff.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
      );

  ToolCallData copyWith({
    String? title,
    String? kind,
    String? status,
    String? command,
    String? output,
    String? outputPreview,
    List<String>? changedFiles,
    List<FileDiff>? diffs,
  }) =>
      ToolCallData(
        id: id,
        title: title ?? this.title,
        kind: kind ?? this.kind,
        status: status ?? this.status,
        command: command ?? this.command,
        output: output ?? this.output,
        outputPreview: outputPreview ?? this.outputPreview,
        changedFiles: changedFiles ?? this.changedFiles,
        diffs: diffs ?? this.diffs,
      );

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! ToolCallData) return false;
    return id == other.id &&
        title == other.title &&
        kind == other.kind &&
        status == other.status &&
        command == other.command &&
        output == other.output &&
        outputPreview == other.outputPreview &&
        _listEquals(changedFiles, other.changedFiles) &&
        _listEquals(diffs, other.diffs);
  }

  @override
  int get hashCode {
    var h = Object.hash(id, title, kind, status, command, output, outputPreview);
    for (final f in changedFiles) {
      h = Object.hash(h, f);
    }
    for (final d in diffs) {
      h = Object.hash(h, d);
    }
    return h;
  }
}

class MessagePart {
  final String type;
  final String? id;
  final String? content;
  final ToolCallData? toolCall;

  MessagePart._({
    required this.type,
    this.id,
    this.content,
    this.toolCall,
  });

  factory MessagePart.text({required String content}) =>
      MessagePart._(type: 'text', content: content);

  factory MessagePart.thinking({required String content}) =>
      MessagePart._(type: 'thinking', content: content);

  factory MessagePart.toolCall({required ToolCallData toolCall}) =>
      MessagePart._(type: 'tool_call', id: toolCall.id, toolCall: toolCall);

  factory MessagePart.fromJson(Map<String, dynamic> j) {
    final type = j['type'] as String? ?? 'text';
    switch (type) {
      case 'text':
        return MessagePart.text(content: j['content'] as String? ?? '');
      case 'thinking':
        return MessagePart.thinking(content: j['content'] as String? ?? '');
      case 'tool_call':
        return MessagePart.toolCall(toolCall: ToolCallData.fromJson(j));
      default:
        return MessagePart.text(content: j['content'] as String? ?? '');
    }
  }

  @override
  String toString() =>
      'MessagePart(type: $type, id: $id, content: $content, toolCall: $toolCall)';

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! MessagePart) return false;
    return type == other.type &&
        id == other.id &&
        content == other.content &&
        toolCall == other.toolCall;
  }

  @override
  int get hashCode => Object.hash(type, id, content, toolCall);
}

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
  }) =>
      Project(
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

  Thread copyWith({
    String? title,
    String? updatedAt,
    bool? pinned,
  }) =>
      Thread(
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

class ThreadDetail {
  final Thread thread;
  List<Message> messages;
  int totalMessages;

  ThreadDetail({
    required this.thread,
    this.messages = const [],
    this.totalMessages = 0,
  });

  factory ThreadDetail.fromJson(Map<String, dynamic> j) => ThreadDetail(
        thread: Thread.fromJson(j['thread'] as Map<String, dynamic>),
        messages: ((j['messages'] as List<dynamic>?) ?? [])
            .map((m) => Message.fromJson(m as Map<String, dynamic>))
            .toList(),
        totalMessages: (j['total_messages'] as num?)?.toInt() ??
            ((j['messages'] as List<dynamic>?) ?? []).length,
      );

  ThreadDetail copyWith({
    Thread? thread,
    List<Message>? messages,
    int? totalMessages,
  }) => ThreadDetail(
        thread: thread ?? this.thread,
        messages: messages ?? this.messages,
        totalMessages: totalMessages ?? this.totalMessages,
      );

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! ThreadDetail) return false;
    return thread == other.thread && totalMessages == other.totalMessages;
  }

  @override
  int get hashCode => Object.hash(thread, totalMessages);
}

class ProviderInfo {
  final String id;
  final String name;

  ProviderInfo({required this.id, required this.name});

  factory ProviderInfo.fromJson(Map<String, dynamic> j) => ProviderInfo(
        id: j['id'] as String,
        name: j['name'] as String? ?? j['id'] as String,
      );
}

class ModelInfo {
  final String id;
  final String label;
  final String costTier;
  final String family;
  final String costSummary;
  final int maxContextTokens;
  final int maxOutputTokens;
  final bool isNew;
  final bool isBeta;

  ModelInfo({
    required this.id,
    required this.label,
    required this.costTier,
    required this.family,
    this.costSummary = '',
    this.maxContextTokens = 0,
    this.maxOutputTokens = 0,
    this.isNew = false,
    this.isBeta = false,
  });

  factory ModelInfo.fromJson(Map<String, dynamic> j) => ModelInfo(
        id: j['id'] as String,
        label: j['label'] as String? ?? j['id'] as String,
        costTier: j['cost_tier'] as String? ?? '',
        family: j['family'] as String? ?? '',
        costSummary: j['cost_summary'] as String? ?? '',
        maxContextTokens: (j['max_context_tokens'] as num?)?.toInt() ?? 0,
        maxOutputTokens: (j['max_output_tokens'] as num?)?.toInt() ?? 0,
        isNew: j['is_new'] as bool? ?? false,
        isBeta: j['is_beta'] as bool? ?? false,
      );
}

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

class TotpSetupResponse {
  final String secret;
  final String otpauthUri;

  TotpSetupResponse({required this.secret, required this.otpauthUri});

  factory TotpSetupResponse.fromJson(Map<String, dynamic> j) => TotpSetupResponse(
        secret: j['secret'] as String,
        otpauthUri: j['otpauth_uri'] as String? ?? '',
      );
}

class PermissionOption {
  final String id;
  final String kind;
  final String? label;

  PermissionOption({
    required this.id,
    required this.kind,
    this.label,
  });

  factory PermissionOption.fromJson(Map<String, dynamic> j) => PermissionOption(
        id: j['id'] as String,
        kind: j['kind'] as String? ?? '',
        label: j['label'] as String?,
      );
}

class PermissionRequest {
  final String requestId;
  final String scope;
  final String title;
  final String? input;
  final List<PermissionOption> options;

  PermissionRequest({
    required this.requestId,
    required this.scope,
    required this.title,
    this.input,
    required this.options,
  });

  factory PermissionRequest.fromJson(Map<String, dynamic> j) => PermissionRequest(
        requestId: j['request_id'] as String,
        scope: j['scope'] as String? ?? '',
        title: j['title'] as String? ?? 'Unknown action',
        input: j['input'] as String?,
        options: (j['options'] as List<dynamic>?)
                ?.map((o) => PermissionOption.fromJson(o as Map<String, dynamic>))
                .toList() ??
            [],
      );
}

class AskOption {
  final String value;
  final String label;

  AskOption({required this.value, required this.label});

  factory AskOption.fromJson(Map<String, dynamic> j) => AskOption(
        value: j['value'] as String? ?? '',
        label: j['label'] as String? ?? '',
      );
}

class AskQuestion {
  final String id;
  final String prompt;
  final String? description;
  final String fieldType;
  final List<AskOption> options;
  final bool required;

  AskQuestion({
    required this.id,
    required this.prompt,
    this.description,
    required this.fieldType,
    this.options = const [],
    this.required = false,
  });

  factory AskQuestion.fromJson(Map<String, dynamic> j) => AskQuestion(
        id: j['id'] as String? ?? '',
        prompt: j['prompt'] as String? ?? '',
        description: j['description'] as String?,
        fieldType: j['field_type'] as String? ?? 'text',
        options: (j['options'] as List<dynamic>?)
                ?.map((o) => AskOption.fromJson(o as Map<String, dynamic>))
                .toList() ??
            const [],
        required: j['required'] as bool? ?? false,
      );

  bool get isText => fieldType == 'text';
  bool get isNumber => fieldType == 'number';
  bool get isBoolean => fieldType == 'boolean';
  bool get isSingleSelect => fieldType == 'single_select';
  bool get isMultiSelect => fieldType == 'multi_select';
}

class AskRequest {
  final String requestId;
  final String message;
  final List<AskQuestion> questions;

  AskRequest({
    required this.requestId,
    required this.message,
    required this.questions,
  });

  factory AskRequest.fromJson(Map<String, dynamic> j) => AskRequest(
        requestId: j['request_id'] as String? ?? '',
        message: j['message'] as String? ?? '',
        questions: (j['questions'] as List<dynamic>?)
                ?.map((q) => AskQuestion.fromJson(q as Map<String, dynamic>))
                .toList() ??
            const [],
      );
}

class GitBranch {
  final String name;
  final String refname;
  final bool isCurrent;
  final bool isDefault;
  final bool isRemote;
  final int committerDate;
  final String? symref;
  final int ahead;
  final int behind;

  GitBranch({
    required this.name,
    required this.refname,
    this.isCurrent = false,
    this.isDefault = false,
    this.isRemote = false,
    this.committerDate = 0,
    this.symref,
    this.ahead = 0,
    this.behind = 0,
  });

  factory GitBranch.fromJson(Map<String, dynamic> j) => GitBranch(
        name: j['name'] as String,
        refname: j['refname'] as String,
        isCurrent: j['is_current'] as bool? ?? false,
        isDefault: j['is_default'] as bool? ?? false,
        isRemote: j['is_remote'] as bool? ?? false,
        committerDate: (j['committer_date'] as num?)?.toInt() ?? 0,
        symref: j['symref'] as String?,
        ahead: (j['ahead'] as num?)?.toInt() ?? 0,
        behind: (j['behind'] as num?)?.toInt() ?? 0,
      );
}

class GitRepoInfo {
  final bool isRepo;
  final String branch;
  final String worktreePath;
  final String toplevel;
  final String commonDir;
  final int ahead;
  final int behind;

  GitRepoInfo({
    this.isRepo = false,
    this.branch = '',
    this.worktreePath = '',
    this.toplevel = '',
    this.commonDir = '',
    this.ahead = 0,
    this.behind = 0,
  });

  factory GitRepoInfo.fromJson(Map<String, dynamic> j) => GitRepoInfo(
        isRepo: j['is_repo'] as bool? ?? false,
        branch: j['branch'] as String? ?? '',
        worktreePath: j['worktree_path'] as String? ?? '',
        toplevel: j['toplevel'] as String? ?? '',
        commonDir: j['common_dir'] as String? ?? '',
        ahead: (j['ahead'] as num?)?.toInt() ?? 0,
        behind: (j['behind'] as num?)?.toInt() ?? 0,
      );
}

class GitWorktree {
  final String path;
  final String head;
  final String? branch;
  final bool isMain;

  GitWorktree({
    required this.path,
    required this.head,
    this.branch,
    this.isMain = false,
  });

  factory GitWorktree.fromJson(Map<String, dynamic> j) => GitWorktree(
        path: j['path'] as String,
        head: j['head'] as String,
        branch: j['branch'] as String?,
        isMain: j['is_main'] as bool? ?? false,
      );
}

class GitStatus {
  final int ahead;
  final int behind;
  final int dirtyFiles;
  final int changedFiles;
  final int insertions;
  final int deletions;

  GitStatus({
    this.ahead = 0,
    this.behind = 0,
    this.dirtyFiles = 0,
    this.changedFiles = 0,
    this.insertions = 0,
    this.deletions = 0,
  });

  factory GitStatus.fromJson(Map<String, dynamic> j) => GitStatus(
        ahead: (j['ahead'] as num?)?.toInt() ?? 0,
        behind: (j['behind'] as num?)?.toInt() ?? 0,
        dirtyFiles: (j['dirty_files'] as num?)?.toInt() ?? 0,
        changedFiles: (j['changed_files'] as num?)?.toInt() ?? 0,
        insertions: (j['insertions'] as num?)?.toInt() ?? 0,
        deletions: (j['deletions'] as num?)?.toInt() ?? 0,
      );
}

class GitConnection {
  final String id;
  final String name;
  final bool enabled;
  final bool available;
  final bool authed;
  final String? account;
  final String? host;
  final bool comingSoon;

  const GitConnection({
    required this.id,
    required this.name,
    this.enabled = false,
    this.available = false,
    this.authed = false,
    this.account,
    this.host,
    this.comingSoon = false,
  });

  factory GitConnection.fromJson(Map<String, dynamic> j) => GitConnection(
        id: j['id'] as String,
        name: j['name'] as String,
        enabled: (j['enabled'] as bool?) ?? false,
        available: (j['available'] as bool?) ?? false,
        authed: (j['authed'] as bool?) ?? false,
        account: j['account'] as String?,
        host: j['host'] as String?,
        comingSoon: (j['coming_soon'] as bool?) ?? false,
      );
}

/// Decode a JSON body that may be either a raw string (error) or a JSON object.
Map<String, dynamic>? tryDecodeJson(String body) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is Map<String, dynamic>) return decoded;
  } catch (_) {}
  return null;
}
