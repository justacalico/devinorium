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

/// A changed file in the index or the working tree, as reported by
/// `GET /api/projects/:id/git/changes`.
class GitChangeEntry {
  final String path;
  final String status;
  final String? origPath;

  GitChangeEntry({required this.path, required this.status, this.origPath});

  factory GitChangeEntry.fromJson(Map<String, dynamic> j) => GitChangeEntry(
    path: j['path'] as String,
    status: j['status'] as String? ?? 'modified',
    origPath: j['orig_path'] as String?,
  );
}

/// Staged and unstaged changes plus tracking state for a repository.
class GitChanges {
  final String branch;
  final int ahead;
  final int behind;
  final List<GitChangeEntry> staged;
  final List<GitChangeEntry> unstaged;

  GitChanges({
    this.branch = '',
    this.ahead = 0,
    this.behind = 0,
    this.staged = const [],
    this.unstaged = const [],
  });

  bool get isClean => staged.isEmpty && unstaged.isEmpty;

  factory GitChanges.fromJson(Map<String, dynamic> j) => GitChanges(
    branch: j['branch'] as String? ?? '',
    ahead: (j['ahead'] as num?)?.toInt() ?? 0,
    behind: (j['behind'] as num?)?.toInt() ?? 0,
    staged: (j['staged'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>()
        .map(GitChangeEntry.fromJson)
        .toList(),
    unstaged: (j['unstaged'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>()
        .map(GitChangeEntry.fromJson)
        .toList(),
  );
}

/// A commit in `GET /api/projects/:id/git/log` output.
class GitCommit {
  final String sha;
  final String subject;
  final String body;
  final String author;
  final String email;
  final int timestamp;
  final String refs;

  GitCommit({
    this.sha = '',
    this.subject = '',
    this.body = '',
    this.author = '',
    this.email = '',
    this.timestamp = 0,
    this.refs = '',
  });

  String get shortSha => sha.length > 7 ? sha.substring(0, 7) : sha;

  factory GitCommit.fromJson(Map<String, dynamic> j) => GitCommit(
    sha: j['sha'] as String? ?? '',
    subject: j['subject'] as String? ?? '',
    body: j['body'] as String? ?? '',
    author: j['author'] as String? ?? '',
    email: j['email'] as String? ?? '',
    timestamp: (j['timestamp'] as num?)?.toInt() ?? 0,
    refs: j['refs'] as String? ?? '',
  );
}

/// One page of `GET /api/projects/:id/git/log` results.
class GitLogPage {
  final List<GitCommit> commits;
  final bool hasMore;

  GitLogPage({this.commits = const [], this.hasMore = false});

  factory GitLogPage.fromJson(Map<String, dynamic> j) => GitLogPage(
    commits: (j['commits'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>()
        .map(GitCommit.fromJson)
        .toList(),
    hasMore: j['has_more'] as bool? ?? false,
  );
}

/// The result of `POST /api/projects/:id/git/commit`.
class GitCommitResult {
  final String sha;
  final String subject;

  GitCommitResult({required this.sha, required this.subject});

  factory GitCommitResult.fromJson(Map<String, dynamic> j) => GitCommitResult(
    sha: j['sha'] as String? ?? '',
    subject: j['subject'] as String? ?? '',
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

/// A merge request reference stored on a thread record.
///
/// Unlike [MergeRequestLink], this does not include live state; it just keeps
/// enough information to resolve the MR in the GitLab UI or to fetch its
/// current summary on demand.
class LinkedMergeRequestRef {
  final String hostname;
  final String projectPath;
  final int iid;
  final String webUrl;

  const LinkedMergeRequestRef({
    required this.hostname,
    required this.projectPath,
    required this.iid,
    required this.webUrl,
  });

  factory LinkedMergeRequestRef.fromJson(Map<String, dynamic> j) =>
      LinkedMergeRequestRef(
        hostname: j['hostname'] as String? ?? '',
        projectPath: j['project_path'] as String? ?? '',
        iid: (j['iid'] as num?)?.toInt() ?? 0,
        webUrl: j['web_url'] as String? ?? '',
      );

  /// Parse a GitLab merge request URL into a reference.
  ///
  /// Accepts any host so self-managed GitLab works. The path must contain the
  /// `/-/merge_requests/` marker.
  static LinkedMergeRequestRef? tryParse(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return null;
    }
    final segs = uri.pathSegments;
    final mrIdx = segs.indexOf('merge_requests');
    if (mrIdx < 2 || segs[mrIdx - 1] != '-') return null;
    if (mrIdx + 1 >= segs.length) return null;
    final iid = int.tryParse(segs[mrIdx + 1]);
    if (iid == null || iid <= 0) return null;
    final projectPath = segs.take(mrIdx - 1).join('/');
    if (projectPath.isEmpty ||
        projectPath.contains(':') ||
        projectPath.contains('..') ||
        projectPath.contains('//')) {
      return null;
    }
    return LinkedMergeRequestRef(
      hostname: (uri.host.isEmpty ? 'gitlab.com' : uri.host).toLowerCase(),
      projectPath: projectPath,
      iid: iid,
      webUrl: url,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! LinkedMergeRequestRef) return false;
    return hostname == other.hostname &&
        projectPath == other.projectPath &&
        iid == other.iid &&
        webUrl == other.webUrl;
  }

  @override
  int get hashCode => Object.hash(hostname, projectPath, iid, webUrl);
}

/// A lightweight merge request reference linked to a thread's branch.
///
/// This is the summary returned by the backend's
/// `GET /api/projects/:id/git/merge-request` endpoint, used to surface the
/// open MR for a thread's branch without loading the full diff payload.
class MergeRequestLink {
  final int iid;
  final String title;
  final String state;
  final String sourceBranch;
  final String targetBranch;
  final String webUrl;
  final bool draft;

  const MergeRequestLink({
    required this.iid,
    required this.title,
    required this.state,
    required this.sourceBranch,
    required this.targetBranch,
    required this.webUrl,
    this.draft = false,
  });

  bool get isOpen => state == 'opened' || state == 'open';

  factory MergeRequestLink.fromJson(Map<String, dynamic> j) {
    final raw = j['iid'];
    final iid = raw is num
        ? raw.toInt()
        : raw is String
        ? int.tryParse(raw) ?? 0
        : 0;
    return MergeRequestLink(
      iid: iid,
      title: j['title'] as String? ?? '',
      state: j['state'] as String? ?? '',
      sourceBranch: j['source_branch'] as String? ?? '',
      targetBranch: j['target_branch'] as String? ?? '',
      webUrl: j['web_url'] as String? ?? '',
      draft: (j['draft'] as bool?) ?? false,
    );
  }

  factory MergeRequestLink.fromRef(LinkedMergeRequestRef ref) => MergeRequestLink(
    iid: ref.iid,
    title: '',
    state: '',
    sourceBranch: '',
    targetBranch: '',
    webUrl: ref.webUrl,
    draft: false,
  );

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! MergeRequestLink) return false;
    return iid == other.iid &&
        title == other.title &&
        state == other.state &&
        sourceBranch == other.sourceBranch &&
        targetBranch == other.targetBranch &&
        webUrl == other.webUrl &&
        draft == other.draft;
  }

  @override
  int get hashCode => Object.hash(
    iid,
    title,
    state,
    sourceBranch,
    targetBranch,
    webUrl,
    draft,
  );
}
