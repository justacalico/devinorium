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

  // ---- Git ----

  Future<GitRepoInfo> gitRepoStatus(int projectId, {bool force = false}) async {
    final params = <String, String>{};
    if (force) params['force'] = 'true';
    final uri = _buildPath('/api/projects/$projectId/git', params);
    final j = await _client.get(uri);
    return GitRepoInfo.fromJson(j);
  }

  Future<GitStatus> gitStatus(int projectId, {bool force = false}) async {
    final params = <String, String>{};
    if (force) params['force'] = 'true';
    final uri = _buildPath('/api/projects/$projectId/git/status', params);
    final j = await _client.get(uri);
    return GitStatus.fromJson(j);
  }

  Future<List<GitBranch>> gitBranches(
    int projectId, {
    String? query,
    int limit = 100,
    bool force = false,
  }) async {
    final params = <String, String>{'limit': limit.toString()};
    if (query != null && query.isNotEmpty) params['query'] = query;
    if (force) params['force'] = 'true';
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

  Future<List<GitWorktree>> gitWorktrees(
    int projectId, {
    bool force = false,
  }) async {
    final params = <String, String>{};
    if (force) params['force'] = 'true';
    final uri = _buildPath('/api/projects/$projectId/git/worktrees', params);
    final list = await _client.getList(uri);
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

  /// Find the open merge request linked to [branch] in the project's GitLab
  /// remote. Returns `null` when there is no open MR, the project has no
  /// GitLab remote, or glab is unavailable — those are expected "no linked
  /// MR" states rather than errors worth surfacing to the user.
  Future<MergeRequestLink?> findMergeRequestForBranch(
    int projectId,
    String branch,
  ) async {
    if (branch.isEmpty) return null;
    final uri = _buildPath('/api/projects/$projectId/git/merge-request', {
      'branch': branch,
    });
    try {
      final j = await _client.get(uri);
      // 204 No Content comes back as an empty map.
      if (j.isEmpty) return null;
      return MergeRequestLink.fromJson(j);
    } on ApiException catch (e) {
      // 404 covers "not a GitLab remote" and "glab not installed".
      if (e.statusCode == 404) return null;
      rethrow;
    }
  }

  /// Load a merge request by its project and IID.
  Future<MergeRequestLink?> findMergeRequestByIid(
    int projectId,
    int iid,
  ) async {
    if (iid <= 0) return null;
    final uri = _buildPath('/api/projects/$projectId/git/merge-request', {
      'iid': iid.toString(),
    });
    try {
      final j = await _client.get(uri);
      if (j.isEmpty) return null;
      return MergeRequestLink.fromJson(j);
    } on ApiException catch (e) {
      if (e.statusCode == 404) return null;
      rethrow;
    }
  }

  // ---- Git connections ----

  Future<List<GitConnection>> listGitConnections() async {
    final list = await _client.getList('/api/git-connections');
    return list.map(GitConnection.fromJson).toList();
  }

  Future<GitConnection> connectGitLab({String? hostname}) async {
    final body = <String, dynamic>{
      if (hostname != null && hostname.isNotEmpty) 'hostname': hostname,
    };
    final j = await _client.post('/api/git-connections/gitlab', body);
    return GitConnection.fromJson(j);
  }

  Future<void> disconnectGitLab({String? hostname}) async {
    await _client.deleteWithBody('/api/git-connections/gitlab', {
      if (hostname != null && hostname.isNotEmpty) 'hostname': hostname,
    });
  }

  // ---- Projects ----

  Future<List<Project>> listProjects({int? limit, int? offset}) async {
    final params = <String, String>{};
    if (limit != null) params['limit'] = limit.toString();
    if (offset != null && offset > 0) params['offset'] = offset.toString();
    final uri = _buildPath('/api/projects', params);
    final list = await _client.getList(uri);
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

  Future<Project> renameProject(int id, String name) async {
    final j = await _client.patch('/api/projects/$id', {'name': name.trim()});
    return Project.fromJson(j);
  }

  Future<Project> pinProject(int id, bool pinned) async {
    final j = await _client.post('/api/projects/$id/pin', {'pinned': pinned});
    return Project.fromJson(j);
  }

  Future<List<Thread>> listThreadsForProject(
    int id, {
    int? limit,
    int? offset,
  }) async {
    final params = <String, String>{};
    if (limit != null) params['limit'] = limit.toString();
    if (offset != null && offset > 0) params['offset'] = offset.toString();
    final uri = _buildPath('/api/projects/$id/threads', params);
    final list = await _client.getList(uri);
    return list.map(Thread.fromJson).toList();
  }

  Future<Map<String, dynamic>> getThreadProject(String id) async {
    return await _client.get('/api/threads/$id/project');
  }

  // ---- Threads ----

  Future<List<Thread>> listThreads({int? limit, int? offset}) async {
    final params = <String, String>{};
    if (limit != null) params['limit'] = limit.toString();
    if (offset != null && offset > 0) params['offset'] = offset.toString();
    final uri = _buildPath('/api/threads', params);
    final list = await _client.getList(uri);
    return list.map(Thread.fromJson).toList();
  }

  Future<Thread> createThread({
    required int projectId,
    String? title,
    int? threadGroupId,
    String? provider,
    String? model,
    String? permissionMode,
    String? reasoningEffort,
    String? permissions,
    String? branch,
    String? worktreePath,
    String? envMode,
  }) async {
    final body = <String, dynamic>{'project_id': projectId};
    if (title != null) body['title'] = title;
    if (threadGroupId != null) body['thread_group_id'] = threadGroupId;
    if (provider != null && provider.isNotEmpty) body['provider'] = provider;
    if (model != null) body['model'] = model;
    if (permissionMode != null) body['permission_mode'] = permissionMode;
    if (reasoningEffort != null) body['reasoning_effort'] = reasoningEffort;
    if (permissions != null) body['permissions'] = permissions;
    if (branch != null) body['branch'] = branch;
    if (worktreePath != null) body['worktree_path'] = worktreePath;
    if (envMode != null && envMode.isNotEmpty) body['env_mode'] = envMode;
    final j = await _client.post('/api/threads', body);
    return Thread.fromJson(j);
  }

  Future<ThreadDetail> getThread(
    String id, {
    bool includeMessages = false,
    int? turnLimit,
  }) async {
    final params = <String, String>{};
    if (includeMessages) params['include_messages'] = '1';
    if (turnLimit != null) params['turn_limit'] = turnLimit.toString();
    final uri = _buildPath('/api/threads/$id', params);
    final meta = await _client.get(uri);
    return ThreadDetail.fromJson(meta);
  }

  Future<MessagePage> getThreadMessages(
    String id, {
    int? beforeId,
    int? afterId,
    int? turnLimit,
    String? beforeCursor,
    int limit = 50,
  }) async {
    final params = <String, String>{};
    if (turnLimit != null || beforeCursor != null) {
      params['turn_limit'] = (turnLimit ?? 50).toString();
      if (beforeCursor != null) params['before_cursor'] = beforeCursor;
    } else {
      params['limit'] = limit.toString();
      if (beforeId != null) params['before_id'] = beforeId.toString();
      if (afterId != null) params['after_id'] = afterId.toString();
    }
    final uri = _buildPath('/api/threads/$id/messages', params);
    final j = await _client.get(uri);
    return MessagePage.fromJson(j);
  }

  Future<Message> getMessageFull(String threadId, int messageId) async {
    final j = await _client.get(
      '/api/threads/$threadId/messages/$messageId/full',
    );
    return Message.fromJson(j['message'] as Map<String, dynamic>);
  }

  Future<Message> getMessageChunk(
    String threadId,
    int messageId, {
    int offset = 0,
    int limit = 100000,
  }) async {
    final params = <String, String>{
      'offset': offset.toString(),
      'limit': limit.toString(),
    };
    final uri = _buildPath(
      '/api/threads/$threadId/messages/$messageId',
      params,
    );
    final j = await _client.get(uri);
    return Message.fromJson(j['message'] as Map<String, dynamic>);
  }

  Future<void> renameThread(String id, String title) async {
    await _client.patch('/api/threads/$id', {'title': title.trim()});
  }

  Future<Thread> pinThread(String id, bool pinned) async {
    final j = await _client.post('/api/threads/$id/pin', {'pinned': pinned});
    return Thread.fromJson(j);
  }

  Future<void> updateThreadSettings(
    String id, {
    String? provider,
    String? model,
    String? permissionMode,
    String? reasoningEffort,
    String? permissions,
    String? envMode,
  }) async {
    final body = <String, dynamic>{};
    if (provider != null && provider.isNotEmpty) body['provider'] = provider;
    if (model != null && model.isNotEmpty) body['model'] = model;
    if (permissionMode != null) body['permission_mode'] = permissionMode;
    if (reasoningEffort != null) body['reasoning_effort'] = reasoningEffort;
    // An empty permissions string is sent as JSON null, which clears the field.
    if (permissions != null) {
      body['permissions'] = permissions.isEmpty ? null : permissions;
    }
    if (envMode != null && envMode.isNotEmpty) body['env_mode'] = envMode;
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

  Future<void> respondAsk(
    String threadId,
    String requestId,
    Map<String, dynamic>? answers,
  ) async {
    await _client.post('/api/threads/$threadId/ask/$requestId', {
      'answers': answers,
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

  Future<void> setThreadLinkedMr(String id, String? url) async {
    await _client.patch('/api/threads/$id', {'linked_mr': url});
  }

  Future<void> moveThreadToGroup(String id, int? groupId) async {
    // null means ungroup; absent means don't change. We always send the field.
    await _client.patch('/api/threads/$id', {'thread_group_id': groupId});
  }

  Future<void> deleteThread(String id) async {
    await _client.delete('/api/threads/$id');
  }

  // ---- Thread Groups ----

  Future<List<ThreadGroup>> listThreadGroups({int? limit, int? offset}) async {
    final params = <String, String>{};
    if (limit != null) params['limit'] = limit.toString();
    if (offset != null && offset > 0) params['offset'] = offset.toString();
    final uri = _buildPath('/api/thread-groups', params);
    final list = await _client.getList(uri);
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

  Future<List<ModelInfo>> listModels({String? provider}) async {
    final params = <String, String>{};
    if (provider != null && provider.isNotEmpty) {
      params['provider'] = provider;
    }
    final uri = _buildPath('/api/models', params);
    final list = await _client.getList(uri);
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
    Map<String, String>? providerCommands,
  }) async {
    final body = <String, dynamic>{
      'provider_id': providerId,
      'provider_command': providerCommand,
    };
    if (providerCommands != null) {
      body['provider_commands'] = providerCommands;
    }
    final j = await _client.patch('/api/auth/me', body);
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

  /// Version info for a provider, defaulting to the user's configured one.
  Future<ProviderVersion> providerVersion({String? provider}) async {
    final params = <String, String>{};
    if (provider != null && provider.isNotEmpty) {
      params['provider'] = provider;
    }
    final j = await _client.get(_buildPath('/api/providers/version', params));
    return ProviderVersion.fromJson(j);
  }

  // ---- Files ----

  Future<FileContent> readFile({
    required String path,
    int? projectId,
    bool includeDiff = false,
  }) async {
    final params = <String, String>{'path': path};
    if (projectId != null) params['project_id'] = projectId.toString();
    if (includeDiff) params['diff'] = 'true';
    final uri = _buildPath('/api/files/content', params);
    final j = await _client.get(uri);
    return FileContent.fromJson(j);
  }

  Future<FileContent> writeFile({
    required String path,
    int? projectId,
    required String content,
    String? expectedSha256,
  }) async {
    final body = <String, dynamic>{'path': path, 'content': content};
    if (projectId != null) body['project_id'] = projectId;
    if (expectedSha256 != null && expectedSha256.isNotEmpty) {
      body['expected_sha256'] = expectedSha256;
    }
    try {
      final j = await _client.put('/api/files/content', body);
      return FileContent.fromJson(j);
    } on ApiException catch (e) {
      if (e.statusCode == 409 && e.data != null) {
        final current = e.data!['current'];
        if (current is Map<String, dynamic>) {
          throw FileConflictException(FileContent.fromJson(current));
        }
      }
      rethrow;
    }
  }

  Future<List<DirEntry>> listFiles({
    String? path,
    int? projectId,
    int? limit,
    int? offset,
  }) async {
    final params = <String, String>{};
    if (path != null && path.isNotEmpty) params['path'] = path;
    if (projectId != null) params['project_id'] = projectId.toString();
    if (limit != null) params['limit'] = limit.toString();
    if (offset != null && offset > 0) params['offset'] = offset.toString();
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

  /// Get the latest plan for a thread.
  Future<Plan?> getThreadPlan(String id) async {
    final j = await _client.get('/api/threads/$id/plan');
    final plan = j['plan'];
    if (plan is Map<String, dynamic>) {
      try {
        return Plan.fromJson(plan);
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  Future<List<String>> getThreadRuns() async {
    final j = await _client.get('/api/threads/runs');
    final list = (j['running_ids'] as List<dynamic>?) ?? [];
    return list.cast<String>();
  }

  /// Watch an existing backend run as an SSE event stream.
  Stream<SseEvent> watchThreadEvents(String id) {
    return _client.getStream(path: '/api/threads/$id/events');
  }

  /// Watch the message stream for a thread.
  Stream<SseEvent> watchMessageStream(
    String threadId, {
    int? sinceSeq,
    int? turnLimit,
    bool live = true,
  }) {
    final params = <String, String>{
      'since_seq': (sinceSeq ?? 0).toString(),
      'turn_limit': (turnLimit ?? 50).toString(),
      'live': live.toString(),
    };
    final uri = _buildPath('/api/threads/$threadId/messages/stream', params);
    return _client.getStream(path: uri);
  }

  /// Stop the currently running model/ACP session for a thread.
  Future<void> stopThread(String id) async {
    await _client.post('/api/threads/$id/stop', {});
  }

  /// Stream a message send. Returns a stream of [SseEvent] records with
  /// `event` ∈ {`user_message`, `permission_request`, `plan_update`, `part`, `part_update`, `done`, `stopped`, `error`}.
  Stream<SseEvent> sendMessageStream({
    required String threadId,
    required String prompt,
    String? mode,
    String? clientMessageId,
    List<({String filename, String mime, Uint8List bytes})> attachments =
        const [],
    List<PathRef> contextPaths = const [],
  }) {
    return _client.sendStream(
      path: '/api/threads/$threadId/send/stream',
      prompt: prompt,
      mode: mode,
      clientMessageId: clientMessageId,
      attachments: attachments,
      contextPaths: contextPaths,
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

  /// Check if the backend is reachable. Returns true on a successful
  /// `/healthz` response, false on any error.
  Future<bool> checkHealth() async {
    try {
      await _client.get('/healthz');
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Fetch the backend version from `/api/server/version`.
  /// Returns `null` if the request fails.
  Future<String?> serverVersion() async {
    try {
      final j = await _client.get('/api/server/version');
      return j['version'] as String?;
    } catch (_) {
      return null;
    }
  }

  // ---- Clone ----

  /// Clone a remote repository into the configured clone root.
  /// Returns the absolute local path on success.
  Future<String> cloneRepo(String url) async {
    final j = await _client.post('/api/clones', {'url': url});
    return j['path'] as String;
  }

  // ---- Clone root ----

  Future<String?> getCloneRoot() async {
    final j = await _client.get('/api/settings/clone-root');
    return j['path'] as String?;
  }

  Future<String?> setCloneRoot(String? path) async {
    final j = await _client.put('/api/settings/clone-root', {'path': path});
    return j['path'] as String?;
  }

  // ---- Usage ----

  /// Fetch the caller's usage summary for the last [days] local days. The
  /// device's timezone offset is sent so day buckets match what the user
  /// experienced.
  Future<UsageSummary> usageSummary({int days = 30}) async {
    final uri = _buildPath('/api/usage', {
      'days': '$days',
      'tz_offset': '${DateTime.now().timeZoneOffset.inMinutes}',
    });
    final j = await _client.get(uri);
    return UsageSummary.fromJson(j);
  }

  // ---- Terminal ----

  /// Create a remote terminal session. [threadId] is optional bookkeeping —
  /// the terminal workspace is global and may outlive the active thread.
  /// Returns the session id.
  Future<String> createTerminalSession(String? threadId) async {
    final j = await _client.post('/api/terminal/sessions', {
      'thread_id': threadId,
    });
    return j['id'] as String;
  }

  /// Kill a remote terminal session.
  Future<void> killTerminalSession(String sessionId) async {
    await _client.delete('/api/terminal/sessions/$sessionId');
  }

  /// Build the WebSocket URL for a remote terminal session.
  Future<Uri> terminalWebSocketUri(String sessionId) async {
    final base = await _client.serverUrl;
    final path = '/api/terminal/sessions/$sessionId/ws';
    if (base == null || base.isEmpty) {
      // Web build: same origin, relative URL.
      return Uri.parse(path);
    }
    return Uri.parse(base).replace(path: path).replace(scheme: 'ws');
  }

  /// Native bearer token for WebSocket auth headers.
  Future<String?> get terminalToken => _client.token;
}

/// Decode a JSON-serialized SSE `data` payload into a [Message].
Message? parseSseMessage(String data) {
  try {
    final decoded = jsonDecode(data);
    if (decoded is Map<String, dynamic>) return Message.fromJson(decoded);
  } catch (_) {}
  return null;
}
