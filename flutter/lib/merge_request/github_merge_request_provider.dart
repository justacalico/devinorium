import 'dart:convert';
import 'dart:typed_data';

import '../api/api_client.dart';
import '../models/models.dart' show LinkedMergeRequestRef;
import '../state/async_value.dart';
import 'merge_request_models.dart';
import 'merge_request_provider.dart';

/// Parses GitHub pull request URLs and loads them through the backend's `gh`
/// proxy.
///
/// Supported URL shapes:
///   https://github.com/owner/repo/pull/1
///   https://corp.ghe.com/owner/repo/pull/1
class GitHubMergeRequestProvider extends MergeRequestProvider {
  final BaseApiClient _client;

  AsyncValue<MergeRequestDetail> _value = const AsyncValue.empty();
  _PullRequestRef? _ref;
  String? _url;

  /// Incremented on every load so a slow fetch cannot overwrite newer data.
  int _generation = 0;
  bool _disposed = false;

  /// Cached file bytes for image diffs, keyed by `ref` + NUL + `path`.
  /// Cleared whenever a different pull request is loaded.
  final Map<String, Uint8List?> _fileCache = {};

  /// Largest repository file that gets loaded for an inline image diff.
  /// Bigger payloads fall back to the text placeholder.
  static const _maxImageFileSize = 10 * 1024 * 1024;

  GitHubMergeRequestProvider(this._client);

  @override
  AsyncValue<MergeRequestDetail> get value => _value;

  @override
  bool get supportsPipelines => true;

  @override
  bool get supportsFiles => true;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  @override
  bool canHandle(String url) => canHandleUrl(url);

  /// Whether [url] is a supported GitHub pull request URL.
  static bool canHandleUrl(String url) => _parseRef(url) != null;

  @override
  Future<void> load(String url) async {
    final generation = ++_generation;
    final ref = _parseRef(url);
    if (ref == null) {
      _ref = null;
      _url = null;
      _emit(AsyncValue.error('Not a supported GitHub pull request URL'));
      return;
    }

    if (!identical(ref, _ref)) _fileCache.clear();
    _ref = ref;
    _url = url;
    _emit(const AsyncValue.loading());

    await _refresh(ref, url, generation);
  }

  @override
  Future<void> perform(MergeRequestAction action) async {
    final ref = _ref;
    final url = _url;
    if (ref == null || url == null) {
      throw StateError('No pull request loaded');
    }

    await _client.post('/api/git-connections/github/merge-requests/actions', {
      'project': ref.projectPath,
      'iid': ref.iid,
      'hostname': ref.hostname,
      'action': action.wire,
    });

    // Increment the generation after the action completes so this refresh wins
    // over any in-flight loads started before the action.
    final generation = ++_generation;

    // Refresh in place so the view keeps its tab and scroll position. The
    // action already succeeded, so a failed refresh keeps the stale detail
    // instead of replacing the view with an error.
    await _refresh(ref, url, generation, keepOnError: true);
  }

  @override
  Future<List<MergeRequestPipelineJob>> loadJobs(
    MergeRequestPipeline pipeline,
  ) async {
    if (pipeline.id <= 0) {
      throw ArgumentError('pipeline id must be positive');
    }
    final ref = _ref;
    if (ref == null) {
      throw StateError('No pull request loaded');
    }

    final query =
        'project=${Uri.encodeQueryComponent(ref.projectPath)}'
        '&pipeline_id=${pipeline.id}'
        '&hostname=${Uri.encodeQueryComponent(ref.hostname)}';
    final response = await _client.get(
      '/api/git-connections/github/pipelines/jobs?$query',
    );
    return (response['_list'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(MergeRequestPipelineJob.fromJson)
        .toList();
  }

  @override
  Future<JobLog> loadJobLog(MergeRequestPipelineJob job) async {
    if (job.id <= 0) {
      throw ArgumentError('job id must be positive');
    }
    final ref = _ref;
    if (ref == null) {
      throw StateError('No pull request loaded');
    }

    final query =
        'project=${Uri.encodeQueryComponent(ref.projectPath)}'
        '&job_id=${job.id}'
        '&hostname=${Uri.encodeQueryComponent(ref.hostname)}';
    final response = await _client.get(
      '/api/git-connections/github/pipelines/jobs/logs?$query',
    );
    return JobLog.fromJson(response);
  }

  /// Load the raw bytes of a repository file at a git ref.
  ///
  /// Uses the contents API through the `gh` proxy, which returns the file
  /// base64-encoded inside JSON — binary-safe without a raw download
  /// endpoint. Returns `null` whenever the file cannot be fetched, so
  /// callers fall back to the text diff.
  @override
  Future<Uint8List?> loadFile(String path, String ref) async {
    final r = _ref;
    if (r == null) {
      throw StateError('No pull request loaded');
    }
    if (path.isEmpty || ref.isEmpty) return null;

    final key = '$ref\x00$path';
    if (_fileCache.containsKey(key)) return _fileCache[key];

    final githubPath =
        'repos/${_encodePath(r.projectPath)}'
        '/contents/${_encodePath(path)}'
        '?ref=${Uri.encodeComponent(ref)}';

    try {
      final response = await _proxy(r, githubPath);
      final size = response['size'];
      if (size is num && size > _maxImageFileSize) {
        return _fileCache[key] = null;
      }
      final content = response['content'];
      if (content is! String || content.isEmpty) {
        return _fileCache[key] = null;
      }
      if (content.length > _maxImageFileSize * 2) {
        return _fileCache[key] = null;
      }
      return _fileCache[key] = base64Decode(
        content.replaceAll(RegExp(r'\s'), ''),
      );
    } catch (_) {
      return _fileCache[key] = null;
    }
  }

  Future<void> _refresh(
    _PullRequestRef ref,
    String url,
    int generation, {
    bool keepOnError = false,
  }) async {
    try {
      final detail = await _fetchDetail(ref, url);
      if (!_stale(generation, ref)) _emit(AsyncValue.ready(detail));
    } catch (e) {
      if (!_stale(generation, ref) && !(keepOnError && _value.isReady)) {
        _emit(AsyncValue.error(e));
      }
    }
  }

  bool _stale(int generation, _PullRequestRef ref) {
    return generation < _generation || !identical(ref, _ref);
  }

  void _emit(AsyncValue<MergeRequestDetail> value) {
    _value = value;
    if (!_disposed) notifyListeners();
  }

  Future<MergeRequestDetail> _fetchDetail(
    _PullRequestRef ref,
    String webUrl,
  ) async {
    final prPath = 'repos/${_encodePath(ref.projectPath)}/pulls/${ref.iid}';

    final pr = await _proxy(ref, prPath);

    final futures = [
      _proxyOrEmpty(ref, '$prPath/files?per_page=100'),
      _proxyOrEmpty(
        ref,
        'repos/${_encodePath(ref.projectPath)}/issues/${ref.iid}/comments?per_page=100',
      ),
      // Inline review comments live on a separate endpoint from the
      // conversation comments.
      _proxyOrEmpty(ref, '$prPath/comments?per_page=100'),
      _pipelines(ref).catchError((_) => <String, dynamic>{'_list': <dynamic>[]}),
    ];

    final results = await Future.wait(futures);
    final files = results[0];
    final commentsJson = results[1];
    final reviewJson = results[2];
    final pipelineJson = results[3];

    final changes = (files['_list'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(_changeFromFile)
        .toList();

    final comments = [
      ...(commentsJson['_list'] as List<dynamic>? ?? []),
      ...(reviewJson['_list'] as List<dynamic>? ?? []),
    ]
        .whereType<Map<String, dynamic>>()
        .map(_commentFromJson)
        .toList()
      ..sort(
        (a, b) => (a.createdAt).compareTo(b.createdAt),
      );

    final pipelineList = pipelineJson['_list'] as List<dynamic>? ?? [];
    final pipelines = pipelineList
        .whereType<Map<String, dynamic>>()
        .map(MergeRequestPipeline.fromJson)
        .toList();

    final head = pr['head'];
    final base = pr['base'];

    return MergeRequestDetail(
      title: _string(pr, 'title') ?? 'Untitled pull request',
      description: _string(pr, 'body') ?? '',
      state: _prState(pr),
      sourceBranch: head is Map<String, dynamic>
          ? _string(head, 'ref') ?? ''
          : '',
      targetBranch: base is Map<String, dynamic>
          ? _string(base, 'ref') ?? ''
          : '',
      iid: _int(pr, 'number') ?? ref.iid,
      webUrl: _string(pr, 'html_url') ?? webUrl,
      draft: _bool(pr, 'draft') ?? false,
      hasConflicts: _bool(pr, 'mergeable') == false,
      mergeWhenPipelineSucceeds: pr['auto_merge'] != null,
      author: _user(pr['user']),
      createdAt: _string(pr, 'created_at') ?? '',
      updatedAt: _string(pr, 'updated_at') ?? '',
      diffBaseSha: base is Map<String, dynamic>
          ? _string(base, 'sha') ?? ''
          : '',
      diffHeadSha: head is Map<String, dynamic>
          ? _string(head, 'sha') ?? ''
          : '',
      changes: changes,
      comments: comments,
      pipelines: pipelines,
    );
  }

  Future<Map<String, dynamic>> _proxy(
    _PullRequestRef ref,
    String githubPath,
  ) async {
    final query =
        'path=${Uri.encodeQueryComponent(githubPath)}'
        '&hostname=${Uri.encodeQueryComponent(ref.hostname)}';
    return _client.get('/api/git-connections/github/proxy?$query');
  }

  Future<Map<String, dynamic>> _proxyOrEmpty(
    _PullRequestRef ref,
    String githubPath,
  ) async {
    try {
      return await _proxy(ref, githubPath);
    } catch (_) {
      return {'_list': <dynamic>[]};
    }
  }

  Future<Map<String, dynamic>> _pipelines(_PullRequestRef ref) async {
    final query =
        'project=${Uri.encodeQueryComponent(ref.projectPath)}'
        '&iid=${ref.iid}'
        '&hostname=${Uri.encodeQueryComponent(ref.hostname)}';
    return _client.get('/api/git-connections/github/pipelines?$query');
  }

  /// GitHub repos are `owner/repo` paths; each segment is encoded
  /// individually so the slash stays a real separator in the API path.
  static String _encodePath(String path) =>
      path.split('/').map(Uri.encodeComponent).join('/');

  /// GitHub reports `state` as only `open`/`closed`; a closed PR that was
  /// merged is surfaced as `merged` so the view shows the same states it
  /// does for GitLab.
  static String _prState(Map<String, dynamic> pr) {
    final merged = _bool(pr, 'merged') == true || pr['merged_at'] != null;
    if (merged) return 'merged';
    return _string(pr, 'state') ?? '';
  }

  /// GitHub's `user` object uses `login`/`avatar_url` instead of
  /// `username`/`avatar_url` like GitLab; map it onto the shared author
  /// shape.
  static MergeRequestAuthor? _user(dynamic userJson) {
    if (userJson is! Map<String, dynamic>) return null;
    return MergeRequestAuthor.fromJson({
      'name': userJson['login'],
      'username': userJson['login'],
      'avatar_url': userJson['avatar_url'],
    });
  }

  static MergeRequestComment _commentFromJson(Map<String, dynamic> j) =>
      MergeRequestComment(
        author: _user(j['user']),
        body: j['body'] as String? ?? '',
        createdAt: j['created_at'] as String? ?? '',
        system: false,
        resolved: false,
      );

  static MergeRequestChange _changeFromFile(Map<String, dynamic> j) {
    final status = j['status'] as String? ?? '';
    final filename = j['filename'] as String? ?? '';
    return MergeRequestChange(
      oldPath: j['previous_filename'] as String? ?? filename,
      newPath: filename,
      diff: j['patch'] as String? ?? '',
      newFile: status == 'added',
      deletedFile: status == 'removed',
      renamedFile: status == 'renamed',
      generatedFile: false,
    );
  }

  static _PullRequestRef? _parseRef(String url) {
    final ref = LinkedMergeRequestRef.tryParse(url);
    if (ref == null || ref.provider != 'github') return null;
    return _PullRequestRef(
      hostname: ref.hostname,
      projectPath: ref.projectPath,
      iid: ref.iid,
    );
  }

  static String? _string(Map<String, dynamic> j, String key) {
    final v = j[key];
    return v is String ? v : null;
  }

  static bool? _bool(Map<String, dynamic> j, String key) {
    final v = j[key];
    return v is bool ? v : null;
  }

  static int? _int(Map<String, dynamic> j, String key) {
    final v = j[key];
    return v is int ? v : (v is num ? v.toInt() : null);
  }
}

class _PullRequestRef {
  final String hostname;
  final String projectPath;
  final int iid;

  const _PullRequestRef({
    required this.hostname,
    required this.projectPath,
    required this.iid,
  });
}
