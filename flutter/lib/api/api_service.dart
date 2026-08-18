import 'dart:convert';
import 'dart:typed_data';

import '../models/models.dart';
import 'api_client.dart';
import 'client_factory.dart';

/// High-level API methods returning typed models. Wraps [ApiClient].
class ApiService {
  final BaseApiClient _client;

  ApiService({BaseApiClient? client}) : _client = client ?? createApiClient();

  BaseApiClient get client => _client;

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

  // ---- Devices ----

  Future<List<Device>> listDevices() async {
    final list = await _client.getList('/api/auth/devices');
    return list.map(Device.fromJson).toList();
  }

  Future<void> revokeDevice(String deviceId) async {
    await _client.post('/api/auth/devices/revoke', {'device_id': deviceId});
  }

  // ---- Git ----

  Future<GitRepoInfo> gitRepoStatus(int projectId) async {
    final j = await _client.get('/api/projects/$projectId/git');
    return GitRepoInfo.fromJson(j);
  }

  Future<GitStatus> gitStatus(int projectId) async {
    final j = await _client.get('/api/projects/$projectId/git/status');
    return GitStatus.fromJson(j);
  }

  Future<List<GitBranch>> gitBranches(
    int projectId, {
    String? query,
    int limit = 100,
  }) async {
    final params = <String, String>{'limit': limit.toString()};
    if (query != null && query.isNotEmpty) params['query'] = query;
    final uri = _buildPath('/api/projects/$projectId/git/branches', params);
    final j = await _client.get(uri);
    final list = (j['branches'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>();
    return list.map(GitBranch.fromJson).toList();
  }

  Future<String> gitCreateBranch(
    int projectId,
    String name, {
    String? base,
    bool switchBranch = false,
  }) async {
    final j = await _client.post('/api/projects/$projectId/git/branches', {
      'name': name,
      'base': base,
      'switch': switchBranch,
    });
    return j['name'] as String;
  }

  Future<void> gitCheckout(
    int projectId,
    String refName, {
    bool track = false,
  }) async {
    await _client.post('/api/projects/$projectId/git/checkout', {
      'ref_name': refName,
      'track': track,
    });
  }

  Future<void> gitPull(int projectId) async {
    await _client.post('/api/projects/$projectId/git/pull', {});
  }

  Future<void> gitPullBranch(int projectId, String name) async {
    await _client.post('/api/projects/$projectId/git/branches/pull', {
      'name': name,
    });
  }

  Future<void> gitPush(int projectId) async {
    await _client.post('/api/projects/$projectId/git/push', {});
  }

  Future<List<GitWorktree>> gitWorktrees(int projectId) async {
    final list = await _client.getList(
      '/api/projects/$projectId/git/worktrees',
    );
    return list.map(GitWorktree.fromJson).toList();
  }

  Future<GitWorktree> gitCreateWorktree(
    int projectId,
    String name,
    String base, {
    bool newBranch = false,
  }) async {
    final j = await _client.post('/api/projects/$projectId/git/worktrees', {
      'name': name,
      'base': base,
      'new_branch': newBranch,
    });
    return GitWorktree.fromJson(j);
  }

  Future<void> gitDeleteWorktree(int projectId, String worktreePath) async {
    await _client.deleteWithBody('/api/projects/$projectId/git/worktrees', {
      'worktree_path': worktreePath,
    });
  }

  // ---- Git connections ----

  Future<List<GitConnection>> listGitConnections() async {
    final list = await _client.getList('/api/git-connections');
    return list.map(GitConnection.fromJson).toList();
  }

  Future<GitConnection> connectGitLab({
    required String token,
    String? hostname,
  }) async {
    final j = await _client.post('/api/git-connections/gitlab', {
      'token': token,
      if (hostname != null && hostname.isNotEmpty) 'hostname': hostname,
    });
    return GitConnection.fromJson(j);
  }

  Future<void> disconnectGitLab({String? hostname}) async {
    await _client.deleteWithBody('/api/git-connections/gitlab', {
      if (hostname != null && hostname.isNotEmpty) 'hostname': hostname,
    });
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

  Future<void> reorderProjects(List<int> projectIds) async {
    await _client.patch('/api/projects/reorder', {'project_ids': projectIds});
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
    String? branch,
    String? worktreePath,
  }) async {
    final body = <String, dynamic>{'project_id': projectId};
    if (title != null) body['title'] = title;
    if (threadGroupId != null) body['thread_group_id'] = threadGroupId;
    if (model != null) body['model'] = model;
    if (permissionMode != null) body['permission_mode'] = permissionMode;
    if (permissions != null) body['permissions'] = permissions;
    if (branch != null) body['branch'] = branch;
    if (worktreePath != null) body['worktree_path'] = worktreePath;
    final j = await _client.post('/api/threads', body);
    return Thread.fromJson(j);
  }

  Future<ThreadDetail> getThread(String id, {bool includeMessages = false}) async {
    final path = includeMessages ? '/api/threads/$id?include_messages=1' : '/api/threads/$id';
    final meta = await _client.get(path);
    final detail = ThreadDetail.fromJson(meta);
    if (detail.messages.isEmpty && detail.totalMessages > 0) {
      final messages = await getThreadMessages(id);
      detail.messages = messages;
    }
    return detail;
  }

  Future<List<Message>> getThreadMessages(
    String id, {
    int? beforeId,
    int? afterId,
    int limit = 50,
  }) async {
    final q = <String, String>{'limit': limit.toString()};
    if (beforeId != null) q['before_id'] = beforeId.toString();
    if (afterId != null) q['after_id'] = afterId.toString();
    final query = q.entries
        .map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    final j = await _client.get('/api/threads/$id/messages?$query');
    return ((j['messages'] as List<dynamic>?) ?? [])
        .map((m) => Message.fromJson(m as Map<String, dynamic>))
        .toList();
  }

  Future<void> renameThread(String id, String title) async {
    await _client.patch('/api/threads/$id', {'title': title});
  }

  Future<void> updateThreadSettings(
    String id, {
    String? model,
    String? permissionMode,
    String? permissions,
  }) async {
    final body = <String, dynamic>{};
    if (model != null && model.isNotEmpty) body['model'] = model;
    if (permissionMode != null) body['permission_mode'] = permissionMode;
    // An empty permissions string is sent as JSON null, which clears the field.
    if (permissions != null) {
      body['permissions'] = permissions.isEmpty ? null : permissions;
    }
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

  Future<void> updateThreadGit(
    String id, {
    String? branch,
    String? worktreePath,
  }) async {
    final body = <String, dynamic>{};
    if (branch != null) body['branch'] = branch;
    if (worktreePath != null) body['worktree_path'] = worktreePath;
    if (body.isNotEmpty) {
      await _client.patch('/api/threads/$id', body);
    }
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

  // ---- Providers ----

  Future<List<ProviderInfo>> listProviders() async {
    final list = await _client.getList('/api/providers');
    return list.map(ProviderInfo.fromJson).toList();
  }

  Future<User> updateMe({
    required String providerId,
    required String providerCommand,
  }) async {
    final j = await _client.patch('/api/auth/me', {
      'provider_id': providerId,
      'provider_command': providerCommand,
    });
    return User.fromJson(j);
  }

  Future<void> testProvider({
    required String providerId,
    required String command,
  }) async {
    await _client.post('/api/providers/health', {
      'provider_id': providerId,
      'command': command,
    });
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

  // ---- Users ----

  Future<List<User>> listUsers() async {
    final list = await _client.getList('/api/users');
    return list.map(User.fromJson).toList();
  }

  Future<void> createUser({
    required String username,
    required String password,
  }) async {
    await _client.post('/api/users', {
      'username': username.trim(),
      'password': password,
    });
  }

  Future<void> setUserDisabled(int id, bool disabled) async {
    await _client.patch('/api/users/$id', {'disabled': disabled});
  }

  // ---- Streaming send ----

  /// Get the current run status for a thread.
  Future<Map<String, dynamic>> getThreadRun(String id) async {
    return await _client.get('/api/threads/$id/run');
  }

  /// Watch an existing backend run as an SSE event stream.
  Stream<SseEvent> watchThreadEvents(String id) {
    return _client.getStream(path: '/api/threads/$id/events');
  }

  /// Stop the currently running model/ACP session for a thread.
  Future<void> stopThread(String id) async {
    await _client.post('/api/threads/$id/stop', {});
  }

  /// Stream a message send. Returns a stream of [SseEvent] records with
  /// `event` ∈ {`user_message`, `permission_request`, `part`, `part_update`, `done`, `stopped`, `error`}.
  Stream<SseEvent> sendMessageStream({
    required String threadId,
    required String prompt,
    String? mode,
    List<({String filename, String mime, Uint8List bytes})> attachments =
        const [],
  }) {
    return _client.sendStream(
      path: '/api/threads/$threadId/send/stream',
      prompt: prompt,
      mode: mode,
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
