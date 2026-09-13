part of 'package:devinorium_frontend/state/app_state.dart';

mixin DialogStore on AppStateBase {
  @override
  DialogKind _dialog = DialogKind.none;
  @override
  String? _mergeRequestUrl;
  @override
  String? _issueUrl;
  @override
  int? _renameProjectId;
  @override
  String? _renameThreadId;
  @override
  String _renameInitialName = '';
  @override
  DialogKind get dialog => _dialog;
  @override
  String? get mergeRequestUrl => _mergeRequestUrl;
  @override
  String? get issueUrl => _issueUrl;
  @override
  int? get renameProjectId => _renameProjectId;
  @override
  String? get renameThreadId => _renameThreadId;
  @override
  String get renameInitialName => _renameInitialName;
  @override
  void openAddProjectDialog() {
    _dialog = DialogKind.addProject;
    _cloneRepoSeq++;
    _cloningRepo = false;
    _cloneRepoResult = null;
    _globalError = '';
    _userMenuOpen = false;
    notifyListeners();
  }
  @override
  void closeDialog() {
    _dialog = DialogKind.none;
    _mergeRequestUrl = null;
    _issueUrl = null;
    _renameProjectId = null;
    _renameThreadId = null;
    _renameProjectGroupId = null;
    _groupAssignProjectId = null;
    _newGroupFromManage = false;
    _renameInitialName = '';
    _cloneRepoSeq++;
    _cloningRepo = false;
    _cloneRepoResult = null;
    notifyListeners();
  }
  @override
  Future<void> openLink(String url) async {
    if (GitLabMergeRequestProvider.canHandleUrl(url)) {
      _mergeRequestUrl = url;
      _dialog = DialogKind.mergeRequest;
      _userMenuOpen = false;
      notifyListeners();
      return;
    }
    if (GitLabIssueProvider.canHandleUrl(url)) {
      _issueUrl = url;
      _dialog = DialogKind.issue;
      _userMenuOpen = false;
      notifyListeners();
      return;
    }
    try {
      await link_opener.openLink(url);
    } catch (e) {
      debugLogFailure('openLink', e);
    }
  }
}
