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
}
