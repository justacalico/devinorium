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
        error: error ?? this.error,
        showDiff: showDiff ?? this.showDiff,
        preview: preview ?? this.preview,
      );
}

mixin EditorStore on AppStateBase {
  final List<EditorTab> _editorTabs = [];
  String? _activeEditorPath;
  bool _agentPanelOpen = true;
  bool _editorFileTreeOpen = true;
  double _editorTreeWidth = 320;
  double _editorAgentPanelWidth = 320;

  static const double _minPanelWidth = 240;
  static const double _maxPanelWidth = 1200;

  @override
  List<EditorTab> get editorTabs => List.unmodifiable(_editorTabs);

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
  bool get editorFileTreeOpen => _editorFileTreeOpen;

  @override
  double get editorTreeWidth => _editorTreeWidth;

  @override
  double get editorAgentPanelWidth => _editorAgentPanelWidth;

  @override
  bool get hasDirtyEditorTabs => _editorTabs.any((t) => t.dirty);

  @override
  void setAgentPanelOpen(bool v) {
    _agentPanelOpen = v;
    notifyListeners();
  }

  @override
  void setEditorFileTreeOpen(bool v) {
    _editorFileTreeOpen = v;
    notifyListeners();
  }

  @override
  void setEditorTreeWidth(double v) {
    _editorTreeWidth = v.clamp(_minPanelWidth, _maxPanelWidth);
    notifyListeners();
  }

  @override
  void setEditorAgentPanelWidth(double v) {
    _editorAgentPanelWidth = v.clamp(_minPanelWidth, _maxPanelWidth);
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

    final tab = EditorTab(path: path, loading: true, preview: true);
    _editorTabs.add(tab);
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
      );
      notifyListeners();
    } catch (e) {
      final idx = _editorTabs.indexWhere((t) => t.path == path);
      if (idx >= 0) {
        _editorTabs[idx] = _editorTabs[idx].copyWith(
          loading: false,
          error: e.toString(),
        );
        notifyListeners();
      }
    }
  }

  @override
  void closeEditorTab(String path) {
    _editorTabs.removeWhere((t) => t.path == path);
    if (_activeEditorPath == path) {
      _activeEditorPath = _editorTabs.isEmpty ? null : _editorTabs.last.path;
    }
    notifyListeners();
  }

  @override
  void closeAllEditorTabs() {
    _editorTabs.clear();
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
      error: null,
      preview: dirty ? false : tab.preview,
    );
    notifyListeners();
  }

  @override
  Future<void> saveEditorTab(String path) async {
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

    _editorTabs[idx] = tab.copyWith(saving: true, error: null);
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
      );
      notifyListeners();
    } on FileConflictException catch (e) {
      final newIdx = _editorTabs.indexWhere((t) => t.path == path);
      if (newIdx < 0) return;
      _editorTabs[newIdx] = _editorTabs[newIdx].copyWith(
        saving: false,
        error: 'file changed on disk',
        content: e.current,
      );
      notifyListeners();
    } catch (e) {
      final newIdx = _editorTabs.indexWhere((t) => t.path == path);
      if (newIdx < 0) return;
      _editorTabs[newIdx] = _editorTabs[newIdx].copyWith(
        saving: false,
        error: e.toString(),
      );
      notifyListeners();
    }
  }

  @override
  Future<void> reloadEditorTab(String path) async {
    final idx = _editorTabs.indexWhere((t) => t.path == path);
    if (idx < 0) return;
    final tab = _editorTabs[idx];
    if (tab.loading || tab.saving) return;

    _editorTabs[idx] = tab.copyWith(loading: true, error: null);
    notifyListeners();

    try {
      final content = await api.readFile(
        path: path,
        projectId: activeProjectId,
      );
      final newIdx = _editorTabs.indexWhere((t) => t.path == path);
      if (newIdx < 0) return;
      _editorTabs[newIdx] = _editorTabs[newIdx].copyWith(
        content: content,
        text: content.text ?? '',
        dirty: false,
        loading: false,
      );
      notifyListeners();
    } catch (e) {
      final newIdx = _editorTabs.indexWhere((t) => t.path == path);
      if (newIdx < 0) return;
      _editorTabs[newIdx] = _editorTabs[newIdx].copyWith(
        loading: false,
        error: e.toString(),
      );
      notifyListeners();
    }
  }
}
