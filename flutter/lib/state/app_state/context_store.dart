part of 'package:devinorium_frontend/state/app_state.dart';

/// Context-window state: the server's usage estimate plus the local draft
/// estimate the composer warns against.
mixin ContextStore on AppStateBase {
  /// The active thread's context usage, or null until it is fetched.
  @override
  ThreadContextUsage? get threadContextUsage => _activeStore?.contextUsage;

  /// Estimated tokens the current draft would add to the next send. Works
  /// without an active store so the counter is right while a thread opens.
  @override
  int get draftContextTokens {
    final store = _activeStore;
    if (store != null) return store.draftTokens;
    var prompt = _composerText.trim();
    if (_composerMode == ComposerMode.ask) prompt = stripAskPrefix(prompt);
    return estimateDraftTokens(
      prompt: prompt,
      mode: _composerMode.name,
      attachments: _attachments,
      pathRefs: _pathRefs,
      threadReferences: _threadReferences,
      machineReferences: _machineReferences,
    );
  }

  /// True when the draft plus session history plus the output reserve would
  /// overflow the model's advertised context window.
  @override
  bool get sendExceedsContext => _activeStore?.sendExceedsContext ?? false;

  /// Drop the provider session and move the usage watermark to now.
  @override
  Future<void> resetThreadContext() async {
    final store = _activeStore;
    if (store == null) return;
    await store.resetContext();
  }

  /// Set or clear the active thread's output-token cap.
  @override
  Future<void> setThreadMaxOutputTokens(int? tokens) async {
    final store = _activeStore;
    if (store == null) return;
    await store.setThreadMaxOutputTokens(tokens);
  }
}
