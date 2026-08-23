import '../api/api_client.dart';
import '../state/async_value.dart';
import 'merge_request_models.dart';
import 'merge_request_provider.dart';

/// Parses GitLab merge request URLs and loads them through the backend's
/// `glab` proxy.
///
/// Supported URL shapes:
///   https://gitlab.com/group/project/-/merge_requests/1
///   https://gitlab.example.com/group/subgroup/project/-/merge_requests/1
class GitLabMergeRequestProvider extends MergeRequestProvider {
  final BaseApiClient _client;

  AsyncValue<MergeRequestDetail> _value = const AsyncValue.empty();

  GitLabMergeRequestProvider(this._client);

  @override
  AsyncValue<MergeRequestDetail> get value => _value;

  @override
  bool canHandle(String url) => canHandleUrl(url);

  /// Whether [url] is a supported GitLab merge request URL.
  static bool canHandleUrl(String url) => _parseRef(url) != null;

  @override
  Future<void> load(String url) async {
    final ref = _parseRef(url);
    if (ref == null) {
      _value = AsyncValue.error('Not a supported GitLab merge request URL');
      notifyListeners();
      return;
    }

    _value = const AsyncValue.loading();
    notifyListeners();

    try {
      final detail = await _fetchDetail(ref, url);
      _value = AsyncValue.ready(detail);
    } catch (e) {
      _value = AsyncValue.error(e);
    }
    notifyListeners();
  }

  Future<MergeRequestDetail> _fetchDetail(_MergeRequestRef ref, String webUrl) async {
    final mrPath = 'projects/${Uri.encodeComponent(ref.projectPath)}/merge_requests/${ref.iid}';

    final results = await Future.wait([
      _proxy(ref, mrPath),
      _proxy(ref, '$mrPath/diffs'),
      _proxy(ref, '$mrPath/notes?per_page=100'),
    ]);

    final mr = results[0];
    final diffs = results[1];
    final notes = results[2];

    final changes = (diffs['_list'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>()
        .map(MergeRequestChange.fromJson)
        .toList();

    final comments = (notes['_list'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>()
        .map(MergeRequestComment.fromJson)
        .toList();

    return MergeRequestDetail(
      title: _string(mr, 'title') ?? 'Untitled merge request',
      description: _string(mr, 'description') ?? '',
      state: _string(mr, 'state') ?? '',
      sourceBranch: _string(mr, 'source_branch') ?? '',
      targetBranch: _string(mr, 'target_branch') ?? '',
      iid: _int(mr, 'iid') ?? ref.iid,
      webUrl: _string(mr, 'web_url') ?? webUrl,
      draft: _bool(mr, 'draft') ?? false,
      hasConflicts: _bool(mr, 'has_conflicts') ?? false,
      author: mr['author'] is Map<String, dynamic>
          ? MergeRequestAuthor.fromJson(mr['author'] as Map<String, dynamic>)
          : null,
      createdAt: _string(mr, 'created_at') ?? '',
      updatedAt: _string(mr, 'updated_at') ?? '',
      changes: changes,
      comments: comments,
    );
  }

  Future<Map<String, dynamic>> _proxy(_MergeRequestRef ref, String gitlabPath) async {
    final query = 'path=${Uri.encodeQueryComponent(gitlabPath)}'
        '&hostname=${Uri.encodeQueryComponent(ref.hostname)}';
    return _client.get('/api/git-connections/gitlab/proxy?$query');
  }

  static _MergeRequestRef? _parseRef(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return null;
    }

    final segs = uri.pathSegments;
    final mrIdx = segs.indexOf('merge_requests');
    if (mrIdx < 2 || segs[mrIdx - 1] != '-') return null;
    if (mrIdx + 1 >= segs.length) return null;

    final iid = int.tryParse(segs[mrIdx + 1]);
    if (iid == null) return null;

    final projectPath = segs.take(mrIdx - 1).join('/');
    if (projectPath.isEmpty) return null;

    return _MergeRequestRef(
      hostname: uri.host.isEmpty ? 'gitlab.com' : uri.host,
      projectPath: projectPath,
      iid: iid,
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

class _MergeRequestRef {
  final String hostname;
  final String projectPath;
  final int iid;

  const _MergeRequestRef({
    required this.hostname,
    required this.projectPath,
    required this.iid,
  });
}
