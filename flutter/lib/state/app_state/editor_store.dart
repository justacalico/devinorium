part of 'package:devinorium_frontend/state/app_state.dart';

class EditorTab {
  final String path;
  FileContent? content;
  String text;
  bool dirty;
  bool loading;
  bool saving;
  String? error;
  bool showDiff;
  bool preview;

  EditorTab({
    required this.path,
    this.content,
    this.text = '',
    this.dirty = false,
    this.loading = false,
    this.saving = false,
    this.error,
    this.showDiff = false,
    this.preview = true,
  });

  String get name => p.basename(path);

  EditorTab copyWith({
    FileContent? content,
    String? text,
    bool? dirty,
    bool? loading,
    bool? saving,
    String? error,
    bool clearError = false,
    bool? showDiff,
    bool? preview,
  }) =>
      EditorTab(
        path: path,
        content: content ?? this.content,
        text: text ?? this.text,
        dirty: dirty ?? this.dirty,
        loading: loading ?? this.loading,
        saving: saving ?? this.saving,
        error: clearError ? null : (error ?? this.error),
        showDiff: showDiff ?? this.showDiff,
        preview: preview ?? this.preview,
      );
}

mixin EditorStore on AppStateBase {
  List<EditorTab> _editorTabs = [];
  List<EditorTab>? _editorTabsView;
  String? _activeEditorPath;
  bool _agentPanelOpen = true;
  bool _agentPanelUserSet = false;
  bool _editorTerminalOpen = false;

  // Tabs that should be reloaded once their in-flight read or write settles.
  final Set<String> _pendingAgentReloads = {};
  double _editorAgentPanelWidth = 320;
  double _editorTerminalHeight = 280;

  static const double _minPanelWidth = 240;
  static const double _maxPanelWidth = 1200;

  void _bumpEditorTabs() {
    _editorTabs = List.of(_editorTabs);
    _editorTabsView = null;
  }

  @override
  List<EditorTab> get editorTabs {
    _editorTabsView ??= List.unmodifiable(_editorTabs);
    return _editorTabsView!;
  }

  @override
  String? get activeEditorPath => _activeEditorPath;

  EditorTab? _tabFor(String path) {
    for (final t in _editorTabs) {
      if (t.path == path) return t;
    }
    return null;
  }

  @override
  EditorTab? get activeEditorTab {
    final path = _activeEditorPath;
    if (path == null) return null;
    return _tabFor(path);
  }

  @override
  bool get agentPanelOpen => _agentPanelOpen;

  @override
  bool get agentPanelUserSet => _agentPanelUserSet;

  @override
  bool get editorTerminalOpen => _editorTerminalOpen;

  @override
  double get editorAgentPanelWidth => _editorAgentPanelWidth;

  @override
  double get editorTerminalHeight => _editorTerminalHeight;

  @override
  bool get hasDirtyEditorTabs => _editorTabs.any((t) => t.dirty);

  @override
  void setAgentPanelOpen(bool v) {
    _agentPanelUserSet = true;
    _agentPanelOpen = v;
    notifyListeners();
  }

  @override
  void setEditorTerminalOpen(bool v) {
    _editorTerminalOpen = v;
    notifyListeners();
  }

  @override
  void setEditorAgentPanelWidth(double v) {
    _editorAgentPanelWidth = v.clamp(_minPanelWidth, _maxPanelWidth);
    notifyListeners();
  }

  @override
  void setEditorTerminalHeight(double v) {
    _editorTerminalHeight = v;
    notifyListeners();
  }

  @override
  void setActiveEditorPath(String? path) {
    _activeEditorPath = path;
    notifyListeners();
  }

  @override
  Future<void> openEditorFile(String path) async {
    if (_tabFor(path) != null) {
      setActiveEditorPath(path);
      return;
    }

    final active = activeEditorTab;
    if (active != null && !active.dirty && active.preview) {
      closeEditorTab(active.path);
    }

    await _openEditorFileImpl(path);
  }

  @override
  Future<void> openEditorFileNewTab(String path) async {
    if (_tabFor(path) != null) {
      setActiveEditorPath(path);
      return;
    }

    await _openEditorFileImpl(path);
  }

  Future<void> _openEditorFileImpl(String path) async {
    try {
      final tab = EditorTab(path: path, loading: true, preview: true);
      _editorTabs.add(tab);
      _bumpEditorTabs();
      _activeEditorPath = path;
      notifyListeners();

      try {
        final content = await api.readFile(
          path: path,
          projectId: activeProjectId,
        );
        final idx = _editorTabs.indexWhere((t) => t.path == path);
        if (idx < 0) return;
        final text = content.text ?? '';
        _editorTabs[idx] = _editorTabs[idx].copyWith(
          content: content,
          text: text,
          dirty: false,
          loading: false,
          clearError: true,
        );
        _bumpEditorTabs();
        notifyListeners();
      } catch (e) {
        final idx = _editorTabs.indexWhere((t) => t.path == path);
        if (idx >= 0) {
          _editorTabs[idx] = _editorTabs[idx].copyWith(
            loading: false,
            error: e.toString(),
          );
          _bumpEditorTabs();
          notifyListeners();
        }
      }
    } finally {
      _drainAgentReload(path);
    }
  }

  @override
  Future<void> openAgentEditedFile(String path) async {
    final existing = _tabFor(path);
    if (existing == null) {
      await _openEditorFileImpl(path);
      return;
    }
    setActiveEditorPath(path);
    // Refresh clean tabs so they show what the agent just wrote instead of
    // the pre-edit contents. A busy tab queues the refresh for when its
    // in-flight read or write settles.
    if (existing.dirty) return;
    if (existing.loading || existing.saving) {
      _pendingAgentReloads.add(path);
      return;
    }
    await reloadEditorTab(path);
  }

  void _drainAgentReload(String path) {
    if (_pendingAgentReloads.remove(path)) {
      unawaited(openAgentEditedFile(path));
    }
  }

  /// Convert a path reported by an agent edit into the form editor tabs
  /// use: project-relative when the file sits under the active project root,
  /// absolute otherwise. Relative paths resolve against the thread's
  /// worktree when one is set, since that is the agent's working directory.
  String _agentEditedEditorPath(ThreadStore store, String raw) {
    if (p.isAbsolute(raw)) {
      final id = _activeProjectId;
      if (id != null) {
        for (final proj in _projects) {
          if (proj.id != id) continue;
          try {
            final rel = p.relative(raw, from: proj.path);
            if (rel != '.' && !rel.startsWith('..')) return rel;
          } catch (_) {}
          break;
        }
      }
      return raw;
    }
    final worktree = store.detail.valueOrNull?.thread.worktreePath;
    if (worktree != null && worktree.isNotEmpty) {
      return p.normalize(p.join(worktree, raw));
    }
    return p.normalize(raw);
  }

  @override
  void closeEditorTab(String path) {
    _editorTabs.removeWhere((t) => t.path == path);
    _pendingAgentReloads.remove(path);
    _bumpEditorTabs();
    if (_activeEditorPath == path) {
      _activeEditorPath = _editorTabs.isEmpty ? null : _editorTabs.last.path;
    }
    notifyListeners();
  }

  @override
  void closeAllEditorTabs() {
    _editorTabs.clear();
    _pendingAgentReloads.clear();
    _bumpEditorTabs();
    _activeEditorPath = null;
    notifyListeners();
  }

  @override
  void setEditorTabText(String path, String text) {
    final idx = _editorTabs.indexWhere((t) => t.path == path);
    if (idx < 0) return;
    final tab = _editorTabs[idx];
    final dirty = text != (tab.content?.text ?? '');
    _editorTabs[idx] = tab.copyWith(
      text: text,
      dirty: dirty,
      clearError: true,
      preview: dirty ? false : tab.preview,
    );
    _bumpEditorTabs();
    notifyListeners();
  }

  @override
  Future<void> saveEditorTab(String path) async {
    try {
      final idx = _editorTabs.indexWhere((t) => t.path == path);
      if (idx < 0) return;
      final tab = _editorTabs[idx];
      if (tab.content == null ||
          tab.content?.text == null ||
          !tab.dirty ||
          tab.saving ||
          tab.loading) {
        return;
      }

      _editorTabs[idx] = tab.copyWith(saving: true, clearError: true);
      _bumpEditorTabs();
      notifyListeners();

      // Capture the text and hash at the moment of the request so we send what
      // the user asked to save, but re-look up the tab after the await in case
      // it was closed or reordered while the network call was in flight.
      final textToSave = _editorTabs[idx].text;
      final expectedSha = _editorTabs[idx].content!.sha256;

      try {
        final content = await api.writeFile(
          path: path,
          projectId: activeProjectId,
          content: textToSave,
          expectedSha256: expectedSha,
        );
        final newIdx = _editorTabs.indexWhere((t) => t.path == path);
        if (newIdx < 0) return;
        _editorTabs[newIdx] = _editorTabs[newIdx].copyWith(
          content: content,
          dirty: _editorTabs[newIdx].text != (content.text ?? ''),
          saving: false,
          preview: false,
          clearError: true,
        );
        _bumpEditorTabs();
        notifyListeners();
      } on FileConflictException catch (e) {
        final newIdx = _editorTabs.indexWhere((t) => t.path == path);
        if (newIdx < 0) return;
        _editorTabs[newIdx] = _editorTabs[newIdx].copyWith(
          saving: false,
          error: 'file changed on disk',
          content: e.current,
        );
        _bumpEditorTabs();
        notifyListeners();
      } catch (e) {
        final newIdx = _editorTabs.indexWhere((t) => t.path == path);
        if (newIdx < 0) return;
        _editorTabs[newIdx] = _editorTabs[newIdx].copyWith(
          saving: false,
          error: e.toString(),
        );
        _bumpEditorTabs();
        notifyListeners();
      }
    } finally {
      _drainAgentReload(path);
    }
  }

  @override
  Future<void> reloadEditorTab(String path) async {
    try {
      final idx = _editorTabs.indexWhere((t) => t.path == path);
      if (idx < 0) return;
      final tab = _editorTabs[idx];
      if (tab.loading || tab.saving) return;

      _editorTabs[idx] = tab.copyWith(loading: true, clearError: true);
      _bumpEditorTabs();
      notifyListeners();

      try {
        final content = await api.readFile(
          path: path,
          projectId: activeProjectId,
        );
        final newIdx = _editorTabs.indexWhere((t) => t.path == path);
        if (newIdx < 0) return;
        final current = _editorTabs[newIdx];
        // The user may have typed while the read was in flight; keep their
        // text and recompute dirty against the fresh on-disk content.
        final text = current.dirty ? current.text : (content.text ?? '');
        _editorTabs[newIdx] = current.copyWith(
          content: content,
          text: text,
          dirty: text != (content.text ?? ''),
          loading: false,
          clearError: true,
        );
        _bumpEditorTabs();
        notifyListeners();
      } catch (e) {
        final newIdx = _editorTabs.indexWhere((t) => t.path == path);
        if (newIdx < 0) return;
        _editorTabs[newIdx] = _editorTabs[newIdx].copyWith(
          loading: false,
          error: e.toString(),
        );
        _bumpEditorTabs();
        notifyListeners();
      }
    } finally {
      _drainAgentReload(path);
    }
  }
}
