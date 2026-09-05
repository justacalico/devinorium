part of 'package:devinorium_frontend/state/app_state.dart';

// ignore_for_file: unused_element
// ignore_for_file: unused_element_parameter

abstract class AppStateBase extends ChangeNotifier {
  MultiServerState get multiServerState;
  ApiService get api;
  AppView get _view;
  set _view(AppView value);
  AppMode get _appMode;
  set _appMode(AppMode value);
  MainPage get _page;
  set _page(MainPage value);
  User? get _user;
  set _user(User? value);
  List<Project> get _projects;
  set _projects(List<Project> value);
  List<Thread> get _threads;
  set _threads(List<Thread> value);
  Set<String> get _runningThreadIds;
  int get _projectsOffset;
  set _projectsOffset(int value);
  bool get _projectsHasMore;
  set _projectsHasMore(bool value);
  bool get _loadingMoreProjects;
  set _loadingMoreProjects(bool value);
  int get _userThreadsOffset;
  set _userThreadsOffset(int value);
  bool get _userThreadsHasMore;
  set _userThreadsHasMore(bool value);
  bool get _loadingMoreUserThreads;
  set _loadingMoreUserThreads(bool value);
  Map<int, int> get _projectThreadOffsets;
  Map<int, bool> get _projectThreadsHasMore;
  Map<int, bool> get _loadingMoreProjectThreads;
  FileTreeNode get _filesTreeRoot;
  set _filesTreeRoot(FileTreeNode value);
  int? get _filesProjectId;
  set _filesProjectId(int? value);
  List<ThreadGroup> get _groups;
  set _groups(List<ThreadGroup> value);
  List<ModelInfo> get _models;
  set _models(List<ModelInfo> value);
  List<ProviderInfo> get _providers;
  set _providers(List<ProviderInfo> value);
  ProviderVersion? get _providerVersion;
  set _providerVersion(ProviderVersion? value);
  int? get _activeProjectId;
  set _activeProjectId(int? value);
  String? get _activeThreadId;
  set _activeThreadId(String? value);
  List<User> get _users;
  set _users(List<User> value);
  String get _loginError;
  set _loginError(String value);
  bool get _showTotpField;
  set _showTotpField(bool value);
  bool get _userMenuOpen;
  set _userMenuOpen(bool value);
  bool get _filesPanelOpen;
  set _filesPanelOpen(bool value);
  bool get _planOverlayVisible;
  set _planOverlayVisible(bool value);
  bool get _planOverlayExpanded;
  set _planOverlayExpanded(bool value);
  bool get _planOverlayUserDismissed;
  set _planOverlayUserDismissed(bool value);
  String get _filesError;
  set _filesError(String value);
  DialogKind get _dialog;
  set _dialog(DialogKind value);
  String? get _mergeRequestUrl;
  set _mergeRequestUrl(String? value);
  String? get _issueUrl;
  set _issueUrl(String? value);
  String get _totpSecret;
  set _totpSecret(String value);
  bool get _threadOpening;
  set _threadOpening(bool value);
  String get _composerText;
  set _composerText(String value);
  List<({String filename, String mime, Uint8List bytes})> get _attachments;
  String get _selectedModel;
  set _selectedModel(String value);
  String get _selectedPermission;
  set _selectedPermission(String value);
  ComposerMode get _composerMode;
  set _composerMode(ComposerMode value);
  Map<String, ThreadStore> get _threadStores;
  ThreadStore? get _activeStore;
  set _activeStore(ThreadStore? value);
  String get _globalError;
  set _globalError(String value);
  String get _lastThreadError;
  set _lastThreadError(String value);
  Locale get _locale;
  set _locale(Locale value);
  int get _settingsTopicIndex;
  set _settingsTopicIndex(int value);
  NotificationService get _notifications;
  Map<int, GitRepoInfo> get _gitRepoInfo;
  Map<int, List<GitBranch>> get _gitBranches;
  Map<int, List<GitWorktree>> get _gitWorktrees;
  MergeRequestLink? get _linkedMergeRequest;
  set _linkedMergeRequest(MergeRequestLink? value);
  bool get _loadingLinkedMergeRequest;
  set _loadingLinkedMergeRequest(bool value);
  int? get _linkedMrProjectId;
  set _linkedMrProjectId(int? value);
  String? get _linkedMrBranch;
  set _linkedMrBranch(String? value);
  int? get _renameProjectId;
  set _renameProjectId(int? value);
  String? get _renameThreadId;
  set _renameThreadId(String? value);
  String get _renameInitialName;
  set _renameInitialName(String value);
  List<GitConnection> get _gitConnections;
  set _gitConnections(List<GitConnection> value);
  bool get _loadingGitConnections;
  set _loadingGitConnections(bool value);
  String? get _cloneRoot;
  set _cloneRoot(String? value);
  bool get _loadingCloneRoot;
  set _loadingCloneRoot(bool value);
  bool get _cloningRepo;
  set _cloningRepo(bool value);
  String? get _cloneRepoResult;
  set _cloneRepoResult(String? value);
  ConnectionStatus get _connectionStatus;
  set _connectionStatus(ConnectionStatus value);
  String? get _serverVersion;
  set _serverVersion(String? value);
  Timer? get _healthTimer;
  set _healthTimer(Timer? value);
  Timer? get _gitRefreshTimer;
  set _gitRefreshTimer(Timer? value);
  bool get _refreshingGit;
  set _refreshingGit(bool value);
  AppView get view;
  AppMode get appMode;
  MainPage get page;
  User? get user;
  List<Project> get projects;
  List<Thread> get threads;
  Set<String> get runningThreadIds;
  List<ThreadGroup> get groups;
  List<ModelInfo> get models;
  List<ProviderInfo> get providers;
  ProviderVersion? get providerVersion;
  int? get activeProjectId;
  String? get activeThreadId;
  ThreadDetail? get activeThreadDetail;
  bool get activeThreadLoading;
  List<User> get users;
  bool get isOwner;
  String get loginError;
  bool get showTotpField;
  bool get userMenuOpen;
  bool get filesPanelOpen;
  bool get planOverlayVisible;
  bool get planOverlayExpanded;
  bool get planOverlayDismissed;
  Plan? get activePlan;
  List<DirEntry> get filesEntries;
  FileTreeNode get filesTreeRoot;
  int? get filesProjectId;
  List<FileTreeRow> get filesTreeRows;
  String get filesError;
  DialogKind get dialog;
  String? get mergeRequestUrl;
  String? get issueUrl;
  MergeRequestLink? get linkedMergeRequest;
  bool get loadingLinkedMergeRequest;
  String get totpSecret;
  String get composerText;
  bool get sending;
  String? get lastRunStatus;
  List<({String filename, String mime, Uint8List bytes})> get attachments;
  String get selectedModel;
  String get selectedPermission;
  ComposerMode get composerMode;
  ComposerMode get defaultComposerMode;
  List<MessagePart> get streamingParts;
  bool get streamingThinkingActive;
  PermissionRequest? get pendingPermissionRequest;
  AskRequest? get pendingAskRequest;
  String? get startedAt;
  String get globalError;
  ConnectionStatus get connectionStatus;
  String? get serverVersion;
  Locale get locale;
  int get settingsTopicIndex;
  bool get notificationsEnabled;
  bool get hasMoreProjects;
  bool get isLoadingMoreProjects;
  bool get hasMoreThreads;
  bool get isLoadingMoreThreads;
  bool get hasMoreFiles;
  bool get isLoadingMoreFiles;
  String? get cloneRoot;
  bool get loadingCloneRoot;
  bool get cloningRepo;
  String? get cloneRepoResult;
  bool hasMoreProjectThreads(int projectId);
  bool isLoadingMoreProjectThreads(int projectId);
  int? get renameProjectId;
  String? get renameThreadId;
  String get renameInitialName;
  void _setActiveStore(ThreadStore? store);
  void _clearLinkedMergeRequest();
  void _onThreadStoreChanged();
  void _syncFromActiveStore();
  ThreadStore _createStore(
    String id, {
    int? projectId,
    ThreadDetail? detail,
    StreamingSnapshot? streaming,
    String? composerText,
    List<({String filename, String mime, Uint8List bytes})>? attachments,
    ComposerMode? composerMode,
    String? selectedModel,
    String? selectedPermission,
  });
  String? _threadTitle(String id);
  GitRepoInfo? gitRepoInfo(int projectId);
  List<GitBranch> gitBranches(int projectId);
  List<GitWorktree> gitWorktrees(int projectId);
  List<GitConnection> get gitConnections;
  bool get loadingGitConnections;
  void setView(AppView v);
  void setAppMode(AppMode m);
  void setPage(MainPage p);
  void setSettingsTopicIndex(int index);
  void toggleUserMenu();
  void setUserMenuOpen(bool v);
  void setComposerText(String t);
  void addAttachments(
    List<({String filename, String mime, Uint8List bytes})> files,
  );
  void removeAttachment(int index);
  void clearAttachments();
  void setSelectedModel(String m);
  void setSelectedPermission(String p);
  void setComposerMode(ComposerMode m, {bool persist});
  Future<void> _saveComposerMode(ComposerMode m);
  Future<void> _loadComposerMode();
  void setLoginError(String e);
  void setShowTotpField(bool v);
  void setGlobalError(String e);
  void clearGlobalError();
  Future<void> setLanguage(String language);
  Future<void> _loadLanguage();
  Future<void> setNotificationsEnabled(bool enabled);
  Future<void> _loadNotificationPrefs();
  Future<void> openFilesPanel();
  void closeFilesPanel();
  Future<void> _loadPlanOverlayState();
  Future<void> _savePlanOverlayState();
  void openPlanOverlay();
  void dismissPlanOverlay();
  void togglePlanOverlay();
  void expandPlanOverlay();
  void collapsePlanOverlay();
  void togglePlanOverlayExpanded();
  Future<void> toggleFilesFolder(FileTreeNode node);
  Future<void> reloadFiles();
  Future<void> loadMoreFiles({FileTreeNode? node});
  @visibleForTesting
  void setFilesEntries(List<DirEntry> entries);
  Future<void> mkdir(String name);
  Future<void> deleteFile(String path);
  Future<void> _loadModelsAndProviders();
  Future<void> refreshProviderVersion();
  Future<void> bootstrap();
  void startHealthChecks();
  void stopHealthChecks();
  void startGitRefresh();
  void stopGitRefresh();
  Future<void> _refreshGitState();
  Future<void> _refreshGitForProject(int projectId);
  Future<void> checkConnection();
  Future<void> loadProjects();
  Future<void> loadMoreProjects();
  Future<void> _loadUserThreadsChunk({bool reset = false});
  Future<void> _loadProjectThreadsChunk(int projectId, {bool reset = false});
  void _mergeThreads(List<Thread> incoming);
  Future<void> refreshThreadsAndGroups();
  Future<void> loadMoreThreads();
  Future<void> loadMoreProjectThreads(int projectId);
  Future<void> refreshRunningThreads();
  Future<void> doLogin({
    required String serverUrl,
    required String username,
    required String password,
    String? totp,
  });
  Future<void> loadUsers();
  Future<void> loadSettingsData();
  Future<void> createUser({required String username, required String password});
  Future<void> setUserDisabled(int id, bool disabled);
  Future<void> logout();
  Future<void> selectProject(int id);
  Future<void> selectAllProjects();
  Future<void> createProject({required String name, required String path});
  void openCloneRepoDialog();
  Future<String?> cloneRepo(String url);
  Future<void> openClonedProjectByPath(String path);
  Future<void> deleteProject(int id);
  Future<void> reorderProjects(List<int> ids);
  Future<void> openNewProjectDialog();
  Future<void> openRenameProjectDialog(int id, String name);
  Future<void> openRenameThreadDialog(String id, String title);
  Future<void> renameProject(int id, String name);
  Future<void> pinProject(int id, bool pinned);
  Future<void> renameThread(String id, String title);
  Future<void> pinThread(String id, bool pinned);
  Future<void> createNewThread({int? projectId});
  Future<void> openThread(String id);
  Future<void> saveProvider({String? providerId, String? providerCommand});
  Future<void> testProvider({
    required String providerId,
    required String command,
  });
  Future<void> saveThreadSettings();
  Future<void> deleteThread(String id);
  Future<void> deleteThreadGroup(int id);
  Future<void> loadMoreMessages();
  Future<void> resumeThread(String id);
  Future<void> sendMessage();
  Future<void> stopThread();
  Future<void> openTotpSetup();
  Future<void> verifyTotp(String code);
  Future<void> disableTotp();
  Future<void> respondToPermissionRequest(String? optionId);
  Future<void> respondToAskRequest(Map<String, dynamic>? answers);
  Future<void> loadGitRepoInfo(int projectId, {bool force = false});
  void _syncProjectBranch(int projectId, GitRepoInfo info);
  Future<void> loadGitBranches(
    int projectId, {
    String? query,
    bool force = false,
  });
  Future<void> loadGitWorktrees(int projectId, {bool force = false});
  Future<void> loadGitBranchData(int projectId);
  Future<void> _loadGitBranchesAndWorktrees(int projectId);
  Future<bool> gitCreateBranch(
    int projectId,
    String name, {
    String? base,
    bool switchBranch = false,
  });
  Future<bool> gitCheckout(int projectId, String refName, {bool track = false});
  Future<bool> gitPull(int projectId);
  Future<bool> gitPullBranch(int projectId, String name);
  Future<bool> gitPush(int projectId);
  Future<GitWorktree?> gitCreateWorktree(
    int projectId,
    String name,
    String base, {
    bool newBranch = false,
  });
  Future<void> gitDeleteWorktree(int projectId, String worktreePath);
  Future<void> setThreadGit(
    String threadId, {
    String? branch,
    String? worktreePath,
  });
  String? get _linkedMrEffectiveBranch;
  Future<void> refreshLinkedMergeRequest();
  Future<void> loadLinkedMergeRequest(int projectId, String branch);
  Future<void> loadCloneRoot();
  Future<void> setCloneRoot(String? path);
  Future<void> loadGitConnections();
  Future<void> connectGitLab({String? hostname});
  Future<void> disconnectGitLab({String? hostname});
  Future<String?> addServer({
    required String serverUrl,
    required String username,
    required String password,
    String? totp,
  });
  Future<void> switchServer(String serverId);
  Future<void> removeServer(String serverId);
  void closeDialog();
  Future<void> openLink(String url);
  Future<PackageInfo> packageInfo() => PackageInfo.fromPlatform();

  // Editor
  List<EditorTab> get editorTabs;
  String? get activeEditorPath;
  EditorTab? get activeEditorTab;
  bool get agentPanelOpen;
  bool get editorTerminalOpen;
  double get editorAgentPanelWidth;
  double get editorTerminalHeight;
  bool get hasDirtyEditorTabs;
  void setEditorAgentPanelWidth(double v);
  void setEditorTerminalHeight(double v);
  Future<void> openEditorFile(String path);
  void closeEditorTab(String path);
  void closeAllEditorTabs();
  void setActiveEditorPath(String? path);
  void setEditorTabText(String path, String text);
  Future<void> saveEditorTab(String path);
  Future<void> reloadEditorTab(String path);
  void setAgentPanelOpen(bool v);
  void setEditorTerminalOpen(bool v);
}
