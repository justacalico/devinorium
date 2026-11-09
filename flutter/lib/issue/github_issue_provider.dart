import '../api/api_client.dart';
import '../merge_request/merge_request_models.dart';
import '../state/async_value.dart';
import 'issue_models.dart';
import 'issue_provider.dart';

/// Parses GitHub issue URLs and loads them through the backend's `gh`
/// proxy.
///
/// Supported URL shapes:
///   https://github.com/owner/repo/issues/1
///   https://corp.ghe.com/owner/repo/issues/42
class GitHubIssueProvider extends IssueProvider {
  final BaseApiClient _client;

  AsyncValue<IssueDetail> _value = const AsyncValue.empty();
  _IssueRef? _ref;

  /// Incremented on every load so a slow fetch cannot overwrite newer data.
  int _generation = 0;
  bool _disposed = false;

  GitHubIssueProvider(this._client);

  @override
  AsyncValue<IssueDetail> get value => _value;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  @override
  bool canHandle(String url) => canHandleUrl(url);

  /// Whether [url] is a supported GitHub issue URL.
  static bool canHandleUrl(String url) => _parseRef(url) != null;

  @override
  Future<void> load(String url) async {
    final generation = ++_generation;
    final ref = _parseRef(url);
    if (ref == null) {
      _ref = null;
      _emit(AsyncValue.error('Not a supported GitHub issue URL'));
      return;
    }

    _ref = ref;
    _emit(const AsyncValue.loading());

    try {
      final detail = await _fetchDetail(ref, url);
      if (!_stale(generation, ref)) _emit(AsyncValue.ready(detail));
    } catch (e) {
      if (!_stale(generation, ref)) _emit(AsyncValue.error(e));
    }
  }

  bool _stale(int generation, _IssueRef ref) {
    return generation < _generation || !identical(ref, _ref);
  }

  void _emit(AsyncValue<IssueDetail> value) {
    _value = value;
    if (!_disposed) notifyListeners();
  }

  Future<IssueDetail> _fetchDetail(_IssueRef ref, String webUrl) async {
    final repoPath =
        'repos/${ref.projectPath.split('/').map(Uri.encodeComponent).join('/')}';
    final issuePath = '$repoPath/issues/${ref.iid}';

    final results = await Future.wait([
      _proxy(ref, issuePath),
      _proxy(ref, '$issuePath/comments?per_page=100'),
    ]);

    final issue = results[0];
    final commentsJson = results[1];

    final comments = (commentsJson['_list'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(_commentFromJson)
        .toList();

    final assignees = (issue['assignees'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(_user)
        .whereType<MergeRequestAuthor>()
        .toList();

    final labels = (issue['labels'] as List<dynamic>? ?? [])
        .map((l) => l is Map<String, dynamic> ? l['name'] as String? : l)
        .whereType<String>()
        .toList();

    final milestoneJson = issue['milestone'];
    final milestone =
        milestoneJson is Map<String, dynamic> ? milestoneJson['title'] as String? : null;

    return IssueDetail(
      title: _string(issue, 'title') ?? 'Untitled issue',
      description: _string(issue, 'body') ?? '',
      state: _string(issue, 'state') ?? '',
      iid: _int(issue, 'number') ?? ref.iid,
      webUrl: _string(issue, 'html_url') ?? webUrl,
      author: _user(issue['user']),
      createdAt: _string(issue, 'created_at') ?? '',
      updatedAt: _string(issue, 'updated_at') ?? '',
      labels: labels,
      milestone: milestone,
      assignees: assignees,
      comments: comments,
    );
  }

  Future<Map<String, dynamic>> _proxy(_IssueRef ref, String githubPath) async {
    final query = 'path=${Uri.encodeQueryComponent(githubPath)}'
        '&hostname=${Uri.encodeQueryComponent(ref.hostname)}';
    return _client.get('/api/git-connections/github/proxy?$query');
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

  static _IssueRef? _parseRef(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return null;
    }

    final segs = uri.pathSegments;
    final idx = segs.indexOf('issues');
    // GitHub repos are exactly `owner/repo` before the `/issues/` marker.
    if (idx != 2 || segs.length <= 3) return null;

    final iid = int.tryParse(segs[3]);
    if (iid == null || iid <= 0) return null;

    final projectPath = segs.take(2).join('/');
    if (projectPath.isEmpty ||
        projectPath.contains(':') ||
        projectPath.contains('..') ||
        projectPath.contains('//')) {
      return null;
    }

    return _IssueRef(
      hostname: (uri.host.isEmpty ? 'github.com' : uri.host).toLowerCase(),
      projectPath: projectPath,
      iid: iid,
    );
  }

  static String? _string(Map<String, dynamic> j, String key) {
    final v = j[key];
    return v is String ? v : null;
  }

  static int? _int(Map<String, dynamic> j, String key) {
    final v = j[key];
    return v is int ? v : (v is num ? v.toInt() : null);
  }
}

class _IssueRef {
  final String hostname;
  final String projectPath;
  final int iid;

  const _IssueRef({
    required this.hostname,
    required this.projectPath,
    required this.iid,
  });
}
