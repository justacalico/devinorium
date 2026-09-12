import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Locale;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_client.dart';
import '../api/api_service.dart';
import '../api/client_factory.dart';
import '../api/native_api_client.dart';
import '../api/preloader_client.dart';
import '../servers/multi_server_state.dart';
import '../servers/server_profile.dart';
import '../services/local_server.dart';
import '../issue/gitlab_issue_provider.dart';
import '../generated/l10n/app_localizations.dart';
import '../l10n/global_l10n.dart';
import '../merge_request/gitlab_merge_request_provider.dart';
import '../models/composer_mode.dart';
import '../utils/link_opener.dart' as link_opener;
import '../utils/debug_log.dart';
import '../utils/permission_modes.dart';
import '../models/models.dart';
import '../services/notification_service.dart';
import '../services/version_checker.dart';
import 'async_value.dart';
import 'streaming_state.dart';
import 'thread_store.dart';

part 'app_state/app_state_base.dart';
part 'app_state/navigation_store.dart';
part 'app_state/core_store.dart';
part 'app_state/auth_store.dart';
part 'app_state/project_store.dart';
part 'app_state/thread_list_store.dart';
part 'app_state/composer_store.dart';
part 'app_state/attachment_store.dart';
part 'app_state/path_refs_store.dart';
part 'app_state/thread_refs_store.dart';
part 'app_state/model_store.dart';
part 'app_state/plan_overlay_store.dart';
part 'app_state/files_panel_store.dart';
part 'app_state/git_panel_store.dart';
part 'app_state/health_check_store.dart';
part 'app_state/lifecycle_store.dart';
part 'app_state/git_store.dart';
part 'app_state/git_refresh_store.dart';
part 'app_state/dialog_store.dart';
part 'app_state/settings_store.dart';
part 'app_state/tailscale_store.dart';
part 'app_state/version_store.dart';
part 'app_state/editor_store.dart';

enum AppView { loading, app }

enum AppMode { agents, editor }

enum MainPage { threads, settings }

enum ConnectionStatus { connected, disconnected, checking }

enum DialogKind {
  none,
  totpSetup,
  newProject,
  cloneRepo,
  permissionRequest,
  renameProject,
  renameThread,
  mergeRequest,
  issue,
  webLogin,
}

class AppState extends AppStateBase
    with
        NavigationStore,
        CoreStore,
        AuthStore,
        ProjectStore,
        ThreadListStore,
        ComposerStore,
        AttachmentStore,
        PathRefsStore,
        ThreadRefsStore,
        ModelStore,
        PlanOverlayStore,
        FilesPanelStore,
        GitPanelStore,
        HealthCheckStore,
        LifecycleStore,
        GitStore,
        GitRefreshStore,
        DialogStore,
        SettingsStore,
        TailscaleStore,
        VersionStore,
        EditorStore {
  @override
  final MultiServerState multiServerState;
  @override
  final LocalServerController localServerManager;

  ApiService? _defaultApi;
  @override
  ApiService get api =>
      multiServerState.activeApi ?? (_defaultApi ??= ApiService());

  /// The list of configured servers, for the UI switcher and settings.
  List<ServerProfile> get serverProfiles => multiServerState.profiles;

  /// The id of the currently active server, or `null`.
  String? get activeServerId => multiServerState.activeServerId;

  AppState({
    MultiServerState? multiServerState,
    ApiService? api,
    VersionChecker? versionChecker,
    LocalServerController? localServerManager,
  }) : multiServerState = multiServerState ?? MultiServerState(),
       localServerManager = localServerManager ?? LocalServerManager() {
    _versionChecker = versionChecker;
    this.multiServerState.addListener(notifyListeners);
    this.localServerManager.onExit = _onLocalServerExit;
    if (api != null) {
      this.multiServerState.addTestConnection(
        ServerProfile(
          id: 'default',
          label: 'default',
          baseUrl: 'http://localhost',
          token: 'token',
          username: 'user',
          createdAt: DateTime.now().toUtc(),
          isPrimary: true,
        ),
        api,
      );
    }
  }

  AppState.test({
    MultiServerState? multiServerState,
    ApiService? api,
    VersionChecker? versionChecker,
    User? user,
    List<User> users = const [],
    List<Project> projects = const [],
    List<Thread> threads = const [],
    List<ThreadGroup> groups = const [],
    List<ModelInfo> models = const [],
    List<ProviderInfo> providers = const [],
    Map<String, ProviderVersion> providerVersions = const {},
    List<GitConnection> gitConnections = const [],
    bool loadingGitConnections = false,
    TailscaleInfo? tailscaleInfo,
    String? cloneRoot,
    bool cloningRepo = false,
    String? cloneRepoResult,
    Map<int, GitRepoInfo> gitRepoInfo = const {},
    MergeRequestLink? linkedMergeRequest,
    int? activeProjectId,
    String? activeThreadId,
    ThreadDetail? activeThreadDetail,
    DialogKind? dialog,
    String? mergeRequestUrl,
    String? issueUrl,
    PermissionRequest? pendingPermissionRequest,
    AskRequest? pendingAskRequest,
    String? globalError,
    Locale? locale,
    int? settingsTopicIndex,
    bool sending = false,
    String? lastRunStatus,
    List<MessagePart> streamingParts = const [],
    bool streamingThinkingActive = false,
    ComposerMode composerMode = ComposerMode.code,
    String? composerText,
    List<({String filename, String mime, Uint8List bytes})> attachments =
        const [],
    List<PathRef> pathRefs = const [],
    List<ThreadReference> threadReferences = const [],
    String? selectedModel,
    String? selectedReasoning,
    String? selectedPermission,
    String? selectedProvider,
    String? startedAt,
    bool threadLoading = false,
    ConnectionStatus connectionStatus = ConnectionStatus.connected,
    String? serverVersion,
    LocalServerController? localServerManager,
  }) : multiServerState = multiServerState ?? MultiServerState(),
       localServerManager =
           localServerManager ?? LocalServerManager.disabled() {
    this.multiServerState.addListener(notifyListeners);
    this.localServerManager.onExit = _onLocalServerExit;
    _versionChecker = versionChecker ?? _NoNetworkVersionChecker();
    if (api != null) {
      this.multiServerState.addTestConnection(
        ServerProfile(
          id: 'test',
          label: 'test',
          baseUrl: 'http://test',
          token: 'token',
          username: user?.username ?? 'test',
          createdAt: DateTime.now().toUtc(),
          isPrimary: true,
        ),
        api,
      );
    }

    _locale = locale ?? const Locale('en');
    _language = locale?.toLanguageTag() ?? 'system';
    _settingsTopicIndex = settingsTopicIndex ?? 0;
    _gitConnections = List<GitConnection>.from(gitConnections);
    _loadingGitConnections = loadingGitConnections;
    _tailscaleInfo = tailscaleInfo;
    _cloneRoot = cloneRoot;
    _cloningRepo = cloningRepo;
    _cloneRepoResult = cloneRepoResult;
    _gitRepoInfo.addAll(gitRepoInfo);
    _linkedMergeRequest = linkedMergeRequest;
    _user = user;
    _users = users;
    _projects = projects;
    _projectsOffset = projects.length;
    _projectsHasMore = false;
    _threads = threads;
    _userThreadsOffset = threads.length;
    _userThreadsHasMore = false;
    if (activeProjectId != null) {
      final projectThreadCount = threads
          .where((t) => t.projectId == activeProjectId)
          .length;
      _projectThreadOffsets[activeProjectId] = projectThreadCount;
      _projectThreadsHasMore[activeProjectId] =
          projectThreadCount == 0 ||
          projectThreadCount >= ThreadListStore._threadChunkSize;
    }
    _groups = groups;
    _models = models;
    _providers = providers;
    _providerVersions.addAll(providerVersions);
    _activeProjectId = activeProjectId;
    _dialog = dialog ?? DialogKind.none;
    _mergeRequestUrl = mergeRequestUrl;
    _issueUrl = issueUrl;
    _globalError = globalError ?? '';
    _composerMode = composerMode;
    _connectionStatus = connectionStatus;
    _serverVersion = serverVersion;

    final threadId = activeThreadId ?? activeThreadDetail?.thread.id;
    if (threadId != null) {
      final detail = activeThreadDetail;
      final projectId = activeProjectId ?? detail?.thread.projectId ?? 0;
      final streaming = StreamingSnapshot(
        phase: sending || streamingParts.isNotEmpty || streamingThinkingActive
            ? StreamPhase.running
            : StreamPhase.idle,
        parts: streamingParts,
        thinkingActive: streamingThinkingActive,
        pendingPermission: pendingPermissionRequest,
        pendingAsk: pendingAskRequest,
        startedAt: startedAt,
      );
      final store = ThreadStore(
        api: this.api,
        threadId: threadId,
        projectId: projectId,
        detail: detail != null ? AsyncValue.ready(detail) : null,
        status: threadLoading ? ThreadStoreStatus.loading : null,
        streaming: streaming,
        composerText: composerText ?? '',
        attachments: attachments,
        pathRefs: pathRefs,
        threadReferences: threadReferences,
        composerMode: composerMode,
        selectedModel: selectedModel ?? '',
        selectedReasoning:
            selectedReasoning ?? detail?.thread.reasoningEffort ?? '',
        selectedPermission: selectedPermission ?? 'normal',
        selectedProvider: selectedProvider ?? detail?.thread.providerId ?? '',
        lastRunStatus: lastRunStatus,
      );
      _threadStores[threadId] = store;
      _setActiveStore(store);
    } else {
      _activeThreadId = activeThreadId;
      _composerText = composerText ?? '';
      _attachments = List.of(attachments);
      _pathRefs = List.of(pathRefs);
      _threadReferences = List.of(threadReferences);
      _selectedModel = selectedModel ?? '';
      _selectedReasoning = selectedReasoning ?? '';
      _selectedPermission = selectedPermission ?? 'normal';
      _selectedProvider = selectedProvider ?? user?.providerId ?? '';
    }
  }

  @override
  void dispose() {
    _versionChecker?.close();
    markDisposed();
    stopHealthChecks();
    _resumeDebounceTimer?.cancel();
    _wantsResume = false;
    _isResuming = false;
    _resumeThreadFuture = null;
    _gitRefreshTimer?.cancel();
    for (final store in _threadStores.values) {
      store.dispose();
    }
    _threadStores.clear();
    _activeStore = null;
    multiServerState.removeListener(notifyListeners);
    localServerManager.dispose();
    super.dispose();
  }

  @override
  void _setActiveStore(ThreadStore? store) {
    if (_activeStore == store) return;
    _activeStore?.onStateChanged = null;
    _activeStore?.onThreadUpdated = null;
    _activeStore?.onRunFinished = null;
    _activeStore?.onAgentEditedFiles = null;
    _activeStore?.cancelStream();
    _activeStore?.clearStreamingState();
    _activeStore = store;
    _activeThreadId = store?.threadId;
    _planOverlayVisible = false;
    // Keep _planOverlayExpanded and _planOverlayUserDismissed as user
    // preferences so they survive thread switches and app restarts.
    store?.onStateChanged = _onThreadStoreChanged;
    if (store != null) _configureStore(store);
    _syncFromActiveStore();
    _clearLinkedMergeRequest();
    notifyListeners();
  }

  @override
  void _onThreadStoreChanged() {
    final store = _activeStore;
    if (store == null) return;
    _syncFromActiveStore();
    notifyListeners();
  }

  @override
  void _syncFromActiveStore() {
    final store = _activeStore;
    if (store == null) return;
    final previousThreadError = _lastThreadError;
    var error = '';
    if (store.globalError.isNotEmpty) {
      error = store.globalError;
    } else if (store.streaming.error != null &&
        store.streaming.error!.isNotEmpty) {
      error = store.streaming.error!;
    }
    if (error.isNotEmpty) {
      _globalError = error;
      _lastThreadError = error;
    } else {
      _lastThreadError = '';
      if (_globalError == previousThreadError) {
        _globalError = '';
      }
    }
    if (store.pendingPermissionRequest != null) {
      _dialog = DialogKind.permissionRequest;
    } else if (_dialog == DialogKind.permissionRequest) {
      _dialog = DialogKind.none;
    }

    // Auto-open the plan overlay when a plan first appears for this thread,
    // unless the user explicitly dismissed it. Preserve the user's preferred
    // collapsed/full state.
    if (!_planOverlayUserDismissed &&
        !_planOverlayVisible &&
        store.plan != null &&
        store.plan!.steps.isNotEmpty) {
      _planOverlayVisible = true;
    }
  }

  void _configureStore(ThreadStore store) {
    final id = store.threadId;
    store.onRunFinished = (failed) {
      final title = _threadTitle(id) ?? 'Thread';
      _notifications.notifyThreadCompleted(title: title, failed: failed);
      final projectId = store.projectId;
      if (projectId > 0) {
        // Refresh branches and worktrees too, not just the repo status: a
        // run may have auto-created a worktree/branch that the toolbar's
        // worktree menu needs to list.
        unawaited(loadGitBranchData(projectId));
      }
      unawaited(loadProjects());
    };
    store.onThreadUpdated = (updated) {
      final index = _threads.indexWhere((t) => t.id == updated.id);
      final previous = index >= 0 ? _threads[index] : null;
      final next = [..._threads];
      if (index >= 0) {
        next[index] = updated;
      }
      next.sort(_compareThreadsForSidebar);
      _threads = next;
      if (updated.id == _activeThreadId &&
          previous?.linkedMr != updated.linkedMr) {
        unawaited(refreshLinkedMergeRequest());
      }
    };
    store.onAgentEditedFiles = (paths) {
      // In editor mode each file the agent edits gets surfaced: open a tab
      // when none exists for the path, focus the tab when it does.
      if (_appMode != AppMode.editor) return;
      for (final raw in paths) {
        try {
          unawaited(openAgentEditedFile(_agentEditedEditorPath(store, raw)));
        } catch (_) {}
      }
    };
  }

  @override
  ThreadStore _createStore(
    String id, {
    int? projectId,
    ThreadDetail? detail,
    StreamingSnapshot? streaming,
    String? composerText,
    List<({String filename, String mime, Uint8List bytes})>? attachments,
    List<PathRef>? pathRefs,
    List<ThreadReference>? threadReferences,
    ComposerMode? composerMode,
    String? selectedModel,
    String? selectedReasoning,
    String? selectedPermission,
    String? selectedProvider,
  }) {
    final store = ThreadStore(
      api: api,
      threadId: id,
      projectId: projectId ?? _activeProjectId ?? 0,
      detail: detail != null ? AsyncValue.ready(detail) : null,
      streaming: streaming,
      composerText: composerText,
      attachments: attachments,
      pathRefs: pathRefs,
      threadReferences: threadReferences,
      composerMode: composerMode,
      selectedModel: selectedModel,
      selectedReasoning: selectedReasoning,
      selectedPermission: selectedPermission,
      selectedProvider: selectedProvider,
    );
    return store;
  }
}
