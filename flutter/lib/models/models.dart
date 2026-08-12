import 'dart:convert';

class User {
  final int id;
  final String username;
  final String role;
  final bool totpEnabled;

  User({
    required this.id,
    required this.username,
    required this.role,
    required this.totpEnabled,
  });

  factory User.fromJson(Map<String, dynamic> j) => User(
        id: (j['id'] as num).toInt(),
        username: j['username'] as String,
        role: j['role'] as String,
        totpEnabled: (j['totp_enabled'] as bool?) ?? false,
      );
}

class LoginResponse {
  final bool ok;
  final bool totpRequired;
  final String username;

  LoginResponse({
    required this.ok,
    required this.totpRequired,
    required this.username,
  });

  factory LoginResponse.fromJson(Map<String, dynamic> j) => LoginResponse(
        ok: (j['ok'] as bool?) ?? false,
        totpRequired: (j['totp_required'] as bool?) ?? false,
        username: j['username'] as String? ?? '',
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
}

class Message {
  final String role;
  final String content;
  final List<Attachment>? attachments;

  Message({
    required this.role,
    required this.content,
    this.attachments,
  });

  factory Message.fromJson(Map<String, dynamic> j) => Message(
        role: j['role'] as String,
        content: j['content'] as String? ?? '',
        attachments: (j['attachments'] as List<dynamic>?)
            ?.map((a) => Attachment.fromJson(a as Map<String, dynamic>))
            .toList(),
      );

  Message copyWith({String? content}) => Message(
        role: role,
        content: content ?? this.content,
        attachments: attachments,
      );
}

class Project {
  final int id;
  final String name;
  final String path;
  final String createdAt;
  final String updatedAt;

  Project({
    required this.id,
    required this.name,
    required this.path,
    required this.createdAt,
    required this.updatedAt,
  });

  factory Project.fromJson(Map<String, dynamic> j) => Project(
        id: (j['id'] as num).toInt(),
        name: j['name'] as String,
        path: j['path'] as String,
        createdAt: j['created_at'] as String? ?? '',
        updatedAt: j['updated_at'] as String? ?? '',
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
        createdAt: j['created_at'] as String? ?? '',
        updatedAt: j['updated_at'] as String? ?? '',
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
  final List<Message> messages;

  ThreadDetail({required this.thread, required this.messages});

  factory ThreadDetail.fromJson(Map<String, dynamic> j) => ThreadDetail(
        thread: Thread.fromJson(j['thread'] as Map<String, dynamic>),
        messages: ((j['messages'] as List<dynamic>?) ?? [])
            .map((m) => Message.fromJson(m as Map<String, dynamic>))
            .toList(),
      );

  ThreadDetail copyWith({List<Message>? messages}) => ThreadDetail(
        thread: thread,
        messages: messages ?? this.messages,
      );
}

class ModelInfo {
  final String id;
  final String label;
  final String costTier;
  final String family;

  ModelInfo({
    required this.id,
    required this.label,
    required this.costTier,
    required this.family,
  });

  factory ModelInfo.fromJson(Map<String, dynamic> j) => ModelInfo(
        id: j['id'] as String,
        label: j['label'] as String? ?? j['id'] as String,
        costTier: j['cost_tier'] as String? ?? '',
        family: j['family'] as String? ?? '',
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

class Invite {
  final String token;
  final int? usedByUserId;
  final String createdAt;
  final String expiresAt;

  Invite({
    required this.token,
    this.usedByUserId,
    required this.createdAt,
    required this.expiresAt,
  });

  factory Invite.fromJson(Map<String, dynamic> j) => Invite(
        token: j['token'] as String,
        usedByUserId: j['used_by_user_id'] as int?,
        createdAt: j['created_at'] as String? ?? '',
        expiresAt: j['expires_at'] as String? ?? '',
      );

  bool get isUsed => usedByUserId != null;
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

/// Decode a JSON body that may be either a raw string (error) or a JSON object.
Map<String, dynamic>? tryDecodeJson(String body) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is Map<String, dynamic>) return decoded;
  } catch (_) {}
  return null;
}
