import 'dart:convert';
import 'dart:typed_data';

import '../models/models.dart';
import 'api_client.dart';

/// High-level API methods returning typed models. Wraps [ApiClient].
class ApiService {
  final ApiClient _client = ApiClient();

  // ---- Auth ----

  Future<User> me() async {
    final j = await _client.get('/api/auth/me');
    return User.fromJson(j);
  }

  Future<LoginResponse> login({
    required String username,
    required String password,
    String? totp,
  }) async {
    final body = <String, dynamic>{
      'username': username.trim(),
      'password': password,
    };
    if (totp != null && totp.trim().isNotEmpty) {
      body['totp'] = totp.trim();
    }
    final j = await _client.post('/api/auth/login', body);
    return LoginResponse.fromJson(j);
  }

  Future<void> logout() async {
    await _client.post('/api/auth/logout', {});
  }

  Future<void> register({
    required String invite,
    required String username,
    required String password,
  }) async {
    await _client.post('/api/auth/register', {
      'invite': invite.trim(),
      'username': username.trim(),
      'password': password,
    });
  }

  Future<TotpSetupResponse> totpSetup() async {
    final j = await _client.post('/api/auth/totp/setup', {});
    return TotpSetupResponse.fromJson(j);
  }

  Future<void> totpVerify(String code) async {
    await _client.post('/api/auth/totp/verify', {'code': code});
  }

  Future<void> totpDisable() async {
    await _client.post('/api/auth/totp/disable', {});
  }

  // ---- Projects ----

  Future<List<Project>> listProjects() async {
    final list = await _client.getList('/api/projects');
    return list.map(Project.fromJson).toList();
  }

  Future<Project> createProject({
    required String name,
    required String path,
  }) async {
    final j = await _client.post('/api/projects', {
      'name': name.trim(),
      'path': path.trim(),
    });
    return Project.fromJson(j);
  }

  Future<void> deleteProject(int id) async {
    await _client.delete('/api/projects/$id');
  }

  Future<List<Thread>> listThreadsForProject(int id) async {
    final list = await _client.getList('/api/projects/$id/threads');
    return list.map(Thread.fromJson).toList();
  }

  Future<Map<String, dynamic>> getThreadProject(String id) async {
    return await _client.get('/api/threads/$id/project');
  }

  // ---- Threads ----

  Future<List<Thread>> listThreads() async {
    final list = await _client.getList('/api/threads');
    return list.map(Thread.fromJson).toList();
  }

  Future<Thread> createThread({
    required int projectId,
    String? title,
    int? threadGroupId,
    String? model,
    String? permissionMode,
    String? permissions,
  }) async {
    final body = <String, dynamic>{
      'project_id': projectId,
    };
    if (title != null) body['title'] = title;
    if (threadGroupId != null) body['thread_group_id'] = threadGroupId;
    if (model != null) body['model'] = model;
    if (permissionMode != null) body['permission_mode'] = permissionMode;
    if (permissions != null) body['permissions'] = permissions;
    final j = await _client.post('/api/threads', body);
    return Thread.fromJson(j);
  }

  Future<ThreadDetail> getThread(String id) async {
    final j = await _client.get('/api/threads/$id');
    return ThreadDetail.fromJson(j);
  }

  Future<void> renameThread(String id, String title) async {
    await _client.patch('/api/threads/$id', {'title': title});
  }

  Future<void> updateThreadSettings(
    String id, {
    String? permissionMode,
    String? permissions,
  }) async {
    final body = <String, dynamic>{};
    if (permissionMode != null) body['permission_mode'] = permissionMode;
    // An empty permissions string is sent as JSON null, which clears the field.
    if (permissions != null) body['permissions'] = permissions.isEmpty ? null : permissions;
    if (body.isNotEmpty) {
      await _client.patch('/api/threads/$id', body);
    }
  }

  Future<void> respondPermission(
    String threadId,
    String requestId,
    String? optionId,
  ) async {
    await _client.post('/api/threads/$threadId/permission/$requestId', {
      'option_id': optionId,
    });
  }

  Future<void> moveThreadToGroup(String id, int? groupId) async {
    // null means ungroup; absent means don't change. We always send the field.
    await _client.patch('/api/threads/$id', {'thread_group_id': groupId});
  }

  Future<void> deleteThread(String id) async {
    await _client.delete('/api/threads/$id');
  }

  // ---- Thread Groups ----

  Future<List<ThreadGroup>> listThreadGroups() async {
    final list = await _client.getList('/api/thread-groups');
    return list.map(ThreadGroup.fromJson).toList();
  }

  Future<ThreadGroup> createThreadGroup({
    String? name,
    List<String>? threadIds,
  }) async {
    final body = <String, dynamic>{};
    if (name != null) body['name'] = name;
    if (threadIds != null) body['thread_ids'] = threadIds;
    final j = await _client.post('/api/thread-groups', body);
    return ThreadGroup.fromJson(j);
  }

  Future<void> renameThreadGroup(int id, String name) async {
    await _client.patch('/api/thread-groups/$id', {'name': name});
  }

  Future<void> deleteThreadGroup(int id) async {
    await _client.delete('/api/thread-groups/$id');
  }

  // ---- Models ----

  Future<List<ModelInfo>> listModels() async {
    final list = await _client.getList('/api/models');
    return list.map(ModelInfo.fromJson).toList();
  }

  // ---- Files ----

  Future<List<DirEntry>> listFiles({String? path, int? projectId}) async {
    final params = <String, String>{};
    if (path != null && path.isNotEmpty) params['path'] = path;
    if (projectId != null) params['project_id'] = projectId.toString();
    final uri = _buildPath('/api/files', params);
    final list = await _client.getList(uri);
    return list.map(DirEntry.fromJson).toList();
  }

  Future<void> mkdir(String path, {int? projectId}) async {
    final body = <String, dynamic>{'path': path};
    if (projectId != null) body['project_id'] = projectId;
    await _client.post('/api/files/dir', body);
  }

  Future<void> deleteFile(String path, {int? projectId}) async {
    final params = <String, String>{'path': path};
    if (projectId != null) params['project_id'] = projectId.toString();
    final uri = _buildPath('/api/files/delete', params);
    await _client.delete(uri);
  }

  Future<void> uploadFiles({
    String? destDir,
    int? projectId,
    required List<({String filename, String mime, Uint8List bytes})> files,
  }) async {
    final fields = <String, String>{};
    if (destDir != null && destDir.isNotEmpty) fields['path'] = destDir;
    if (projectId != null) fields['project_id'] = projectId.toString();
    await _client.uploadMultipart('/api/files', fields, files);
  }

  // ---- Invites ----

  Future<List<Invite>> listInvites() async {
    final list = await _client.getList('/api/invites');
    return list.map(Invite.fromJson).toList();
  }

  Future<String> createInvite() async {
    final j = await _client.post('/api/invites', {});
    return j['token'] as String;
  }

  // ---- Streaming send ----

  /// Stream a message send. Returns a stream of [SseEvent] records with
  /// `event` ∈ {`user_message`, `permission_request`, `chunk`, `done`, `error`}.
  Stream<SseEvent> sendMessageStream({
    required String threadId,
    required String prompt,
    List<({String filename, String mime, Uint8List bytes})> attachments =
        const [],
  }) {
    return _client.sendStream(
      path: '/api/threads/$threadId/send/stream',
      prompt: prompt,
      attachments: attachments,
    );
  }

  /// Build a path with optional query parameters, encoding values safely.
  static String _buildPath(String path, Map<String, String> params) {
    if (params.isEmpty) return path;
    final buffer = StringBuffer(path);
    var first = true;
    for (final e in params.entries) {
      buffer.write(first ? '?' : '&');
      buffer.write('${Uri.encodeQueryComponent(e.key)}=');
      buffer.write(Uri.encodeQueryComponent(e.value));
      first = false;
    }
    return buffer.toString();
  }
}

/// Decode a JSON-serialized SSE `data` payload into a [Message].
Message? parseSseMessage(String data) {
  try {
    final decoded = jsonDecode(data);
    if (decoded is Map<String, dynamic>) return Message.fromJson(decoded);
  } catch (_) {}
  return null;
}
