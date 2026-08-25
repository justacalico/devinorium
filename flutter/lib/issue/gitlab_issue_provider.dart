import '../api/api_client.dart';
import '../merge_request/merge_request_models.dart';
import '../state/async_value.dart';
import 'issue_models.dart';
import 'issue_provider.dart';

/// Parses GitLab issue / work-item URLs and loads them through the
/// backend's `glab` proxy.
///
/// Supported URL shapes:
///   https://gitlab.com/group/project/-/issues/1
///   https://gitlab.example.com/group/subgroup/project/-/issues/42
///   https://gitlab.com/group/project/-/work_items/1
class GitLabIssueProvider extends IssueProvider {
  final BaseApiClient _client;

  AsyncValue<IssueDetail> _value = const AsyncValue.empty();
  _IssueRef? _ref;

  /// Incremented on every load so a slow fetch cannot overwrite newer data.
  int _generation = 0;
  bool _disposed = false;

  GitLabIssueProvider(this._client);

  @override
  AsyncValue<IssueDetail> get value => _value;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  @override
  bool canHandle(String url) => canHandleUrl(url);

  /// Whether [url] is a supported GitLab issue URL.
  static bool canHandleUrl(String url) => _parseRef(url) != null;

  @override
  Future<void> load(String url) async {
    final generation = ++_generation;
    final ref = _parseRef(url);
    if (ref == null) {
      _ref = null;
      _emit(AsyncValue.error('Not a supported GitLab issue URL'));
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
    final issuePath =
        'projects/${Uri.encodeComponent(ref.projectPath)}/issues/${ref.iid}';

    final results = await Future.wait([
      _proxy(ref, issuePath),
      _proxy(ref, '$issuePath/notes?per_page=100'),
    ]);

    final issue = results[0];
    final notes = results[1];

    final comments = (notes['_list'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(MergeRequestComment.fromJson)
        .toList();

    final assignees = (issue['assignees'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(MergeRequestAuthor.fromJson)
        .toList();

    final labels = (issue['labels'] as List<dynamic>? ?? [])
        .whereType<String>()
        .toList();

    final milestoneJson = issue['milestone'];
    final milestone =
        milestoneJson is Map<String, dynamic> ? milestoneJson['title'] as String? : null;

    return IssueDetail(
      title: _string(issue, 'title') ?? 'Untitled issue',
      description: _string(issue, 'description') ?? '',
      state: _string(issue, 'state') ?? '',
      iid: _int(issue, 'iid') ?? ref.iid,
      webUrl: _string(issue, 'web_url') ?? webUrl,
      author: issue['author'] is Map<String, dynamic>
          ? MergeRequestAuthor.fromJson(issue['author'] as Map<String, dynamic>)
          : null,
      createdAt: _string(issue, 'created_at') ?? '',
      updatedAt: _string(issue, 'updated_at') ?? '',
      labels: labels,
      milestone: milestone,
      assignees: assignees,
      comments: comments,
    );
  }

  Future<Map<String, dynamic>> _proxy(_IssueRef ref, String gitlabPath) async {
    final query = 'path=${Uri.encodeQueryComponent(gitlabPath)}'
        '&hostname=${Uri.encodeQueryComponent(ref.hostname)}';
    return _client.get('/api/git-connections/gitlab/proxy?$query');
  }

  static _IssueRef? _parseRef(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return null;
    }

    final segs = uri.pathSegments;
    var idx = segs.indexOf('issues');
    if (idx == -1) idx = segs.indexOf('work_items');
    if (idx < 2 || segs[idx - 1] != '-') return null;
    if (idx + 1 >= segs.length) return null;

    final iid = int.tryParse(segs[idx + 1]);
    if (iid == null) return null;

    final projectPath = segs.take(idx - 1).join('/');
    if (projectPath.isEmpty) return null;

    return _IssueRef(
      hostname: uri.host.isEmpty ? 'gitlab.com' : uri.host,
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
