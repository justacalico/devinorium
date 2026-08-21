import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/api_client.dart';
import '../api/api_service.dart';
import '../l10n/global_l10n.dart';
import '../models/composer_mode.dart';
import '../models/models.dart';
import 'async_value.dart';
import 'command_scheduler.dart';
import 'streaming_reducer.dart';
import 'streaming_state.dart';

/// Lifecycle status for an individual thread store.
enum ThreadStoreStatus { empty, loading, ready, error, deleted }

/// Per-thread state and lifecycle.
///
/// t3code treats every thread as an isolated event-sourced unit with its own
/// state, subscription, and command queue. This is the Dart equivalent:
/// one store per thread id, with a pure reducer for stream events, a cancellable
/// stream token, and explicit status values.
class ThreadStore {
  final ApiService api;
  final String threadId;
  final int projectId;

  ThreadStore({
    required this.api,
    required this.threadId,
    required this.projectId,
    ThreadStoreStatus? status,
    AsyncValue<ThreadDetail>? detail,
    StreamingSnapshot? streaming,
    String? composerText,
    List<({String filename, String mime, Uint8List bytes})>? attachments,
    ComposerMode? composerMode,
    String? selectedModel,
    String? selectedPermission,
    String? lastRunStatus,
  }) : _status = status ?? ThreadStoreStatus.empty,
       _detail = detail ?? const AsyncValue.empty(),
       _streaming = streaming ?? StreamingSnapshot.empty,
       composerText = composerText ?? '',
       attachments = attachments == null ? [] : List.of(attachments),
       composerMode = composerMode ?? ComposerMode.code,
       selectedModel = selectedModel ?? '',
       selectedPermission = selectedPermission ?? 'normal' {
    _lastRunStatus = lastRunStatus;
  }

  ThreadStoreStatus _status;
  AsyncValue<ThreadDetail> _detail;
  StreamingSnapshot _streaming;
  String _globalError = '';
  String? _lastRunStatus;

  // Draft state for this thread. t3code keeps a per-thread draft so switching
  // threads does not lose the user's in-progress input.
  String composerText;
  final List<({String filename, String mime, Uint8List bytes})> attachments;
  ComposerMode composerMode;
  String selectedModel;
  String selectedPermission;

  // Stream lifecycle.
  StreamSubscription? _subscription;
  int _streamToken = 0;

  // t3code-style serial command queue for this thread.
  final ThreadCommandScheduler _scheduler = ThreadCommandScheduler();

  /// Called whenever any piece of thread state changes.
  VoidCallback? onStateChanged;

  /// Called when a run finishes (completed or failed). The [failed] flag
  /// indicates whether the run ended with an error.
  void Function(bool failed)? onRunFinished;

  // ---- getters ----

  ThreadStoreStatus get status => _status;
  AsyncValue<ThreadDetail> get detail => _detail;
  StreamingSnapshot get streaming => _streaming;
  String get globalError => _globalError;
  String? get lastRunStatus => _lastRunStatus;

  bool get sending => _streaming.isActive;
  List<MessagePart> get streamingParts => _streaming.parts;
  bool get streamingThinkingActive => _streaming.thinkingActive;
  PermissionRequest? get pendingPermissionRequest => _streaming.pendingPermission;
  AskRequest? get pendingAskRequest => _streaming.pendingAsk;
  String? get startedAt => _streaming.startedAt;

  /// Load the persisted detail and, if the server says the thread is still
  /// running, resume the live stream. This is t3code's "snapshot then
  /// subscribe" pattern.
  Future<void> load() async {
    _status = ThreadStoreStatus.loading;
    _emit();
    try {
      final [detail, run] = await Future.wait([
        api.getThread(threadId, includeMessages: true),
        api.getThreadRun(threadId),
      ]);
      final d = detail as ThreadDetail;
      _detail = AsyncValue.ready(d);
      selectedModel = d.thread.model;
      selectedPermission = d.thread.permissionMode;
      _status = ThreadStoreStatus.ready;
      _globalError = '';
      _emit();

      _applyRunSnapshot(run as Map<String, dynamic>);
    } catch (e) {
      _status = ThreadStoreStatus.error;
      _globalError = '$e';
      _emit();
    }
  }

  /// Explicitly refresh the persisted detail without touching the stream.
  Future<void> reloadDetail() async {
    try {
      final d = await api.getThread(threadId);
      _detail = AsyncValue.ready(d);
      _globalError = '';
      _emit();
    } catch (e) {
      _globalError = '$e';
      _emit();
    }
  }

  /// Resume a run that is already in progress on the server.
  Future<void> resume() async {
    _globalError = '';
    _emit();
    await _scheduler.run('stream', () async {
      try {
        final token = _streamToken;
        final run = await api.getThreadRun(threadId);
        // If the store was deactivated or disposed while we were waiting,
        // do not apply a stale run snapshot or start a new stream.
        if (token != _streamToken || onStateChanged == null) return;
        _applyRunSnapshot(run);
        _lastRunStatus = run['status'] as String?;
        if (_lastRunStatus == 'running') {
          _runFinishedFired = false;
          _startStream(_nextStreamToken());
        } else {
          _finishResume(run);
          await reloadDetail();
        }
      } catch (e) {
        _globalError = '$e';
        _emit();
      }
    });
  }

  /// Send a user message and start a new streaming turn.
  Future<void> sendMessage() async {
    final prompt = composerText.trim();
    if (prompt.isEmpty) return;
    _globalError = '';

    await _scheduler.run('stream', () async {
      final token = _nextStreamToken();
      try {
        await saveSettings();
      } catch (_) {
        return;
      }
      if (token != _streamToken || onStateChanged == null) return;

      _clearStreamingState();
      _streaming = _streaming.copyWith(phase: StreamPhase.sending);
      _lastRunStatus = 'running';
      _runFinishedFired = false;
      debugPrint('[notify] sendMessage: thread=$threadId token=$token phase=sending');
      _emit();

      final messageAttachments = List<({String filename, String mime, Uint8List bytes})>.of(
        attachments,
      );

      try {
        _subscription = api
            .sendMessageStream(
              threadId: threadId,
              prompt: prompt,
              mode: composerMode.name,
              attachments: messageAttachments,
            )
            .listen(
              (ev) => _handleEvent(ev, token),
              onError: (e) => _handleStreamError(e, token),
              onDone: () => _handleStreamDone(token),
            );
      } catch (e) {
        _finishStream(error: '$e', phase: StreamPhase.failed);
      }
    });
  }

  /// Persist the selected model and permission mode for this thread.
  Future<void> saveSettings() async {
    try {
      await api.updateThreadSettings(
        threadId,
        model: selectedModel.isEmpty ? null : selectedModel,
        permissionMode: selectedPermission,
      );
      final d = await api.getThread(threadId);
      _detail = AsyncValue.ready(d);
      _globalError = '';
      _emit();
    } catch (e) {
      _globalError = '$e';
      _emit();
    }
  }

  /// Ask the server to stop the current run.
  Future<void> stop() async {
    await _scheduler.run('stream', () async {
      try {
        await api.stopThread(threadId);
      } catch (e) {
        _globalError = '$e';
        _emit();
      }
    });
  }

  /// Respond to a permission request.
  Future<void> respondToPermissionRequest(String? optionId) async {
    final req = _streaming.pendingPermission;
    if (req == null) return;
    await _scheduler.run('stream', () async {
      try {
        await api.respondPermission(threadId, req.requestId, optionId);
        _streaming = _streaming.copyWith(clearPendingPermission: true);
        _emit();
      } catch (e) {
        _globalError = '$e';
        _emit();
      }
    });
  }

  /// Respond to an ask request with the user's answers.
  Future<void> respondToAskRequest(Map<String, dynamic>? answers) async {
    final req = _streaming.pendingAsk;
    if (req == null) return;
    await _scheduler.run('stream', () async {
      try {
        await api.respondAsk(threadId, req.requestId, answers);
        _streaming = _streaming.copyWith(clearPendingAsk: true);
        _emit();
      } catch (e) {
        _globalError = '$e';
        _emit();
      }
    });
  }

  /// Load the next page of older messages.
  Future<void> loadMoreMessages() async {
    final d = _detail.valueOrNull;
    if (d == null) return;
    if (d.messages.isEmpty) return;
    if (d.messages.length >= d.totalMessages) return;
    final oldestId = d.messages.first.id;
    if (oldestId == null) return;
    try {
      final older = await api.getThreadMessages(threadId, beforeId: oldestId);
      if (older.isNotEmpty) {
        _detail = AsyncValue.ready(d.copyWith(
          messages: [...older, ...d.messages],
        ));
        _emit();
      }
    } catch (e) {
      _globalError = '$e';
      _emit();
    }
  }

  /// Refresh the tail of the message list after a run finishes.
  Future<void> refreshTail() async {
    final d = _detail.valueOrNull;
    if (d == null || d.messages.isEmpty) {
      await reloadDetail();
      return;
    }
    final newestId = d.messages.last.id;
    if (newestId == null) {
      await reloadDetail();
      return;
    }
    try {
      final tail = await api.getThreadMessages(threadId, afterId: newestId);
      if (tail.isNotEmpty) {
        _detail = AsyncValue.ready(d.copyWith(
          messages: [...d.messages, ...tail],
          totalMessages: d.totalMessages + tail.length,
        ));
        _emit();
      }
    } catch (_) {
      await reloadDetail();
    }
  }

  /// Cancel the live stream without clearing the snapshot.
  /// Used when the user switches away and we want to stop listening but keep
  /// the cached running state.
  void cancelStream() {
    _cancelStream();
  }

  /// Clear the transient streaming state (parts, thinking, status).
  void clearStreamingState() {
    _clearStreamingState();
    _emit();
  }

  /// Mark this thread as deleted. The store may still be cached, but any
  /// further operation is a no-op.
  void markDeleted() {
    _status = ThreadStoreStatus.deleted;
    _cancelStream();
    _emit();
  }

  /// Dispose the store, cancelling any in-flight stream.
  void dispose() {
    _cancelStream();
    _scheduler.dispose();
    onStateChanged = null;
    _emit();
  }

  // ---- private ----

  void _emit() {
    onStateChanged?.call();
  }

  void _applyRunSnapshot(Map<String, dynamic> run) {
    _streaming = runSnapshotFromJson(run);
    _lastRunStatus = run['status'] as String?;
    _emit();
  }

  void _cancelStream() {
    _streamToken += 1;
    _subscription?.cancel();
    _subscription = null;
  }

  void _clearStreamingState() {
    _streaming = StreamingSnapshot.empty;
    _lastRunStatus = null;
  }

  int _nextStreamToken() {
    _cancelStream();
    _streamToken += 1;
    return _streamToken;
  }

  void _startStream(int token) {
    _subscription = api.watchThreadEvents(threadId).listen(
          (ev) => _handleEvent(ev, token),
          onError: (e) => _handleStreamError(e, token),
          onDone: () => _handleStreamDone(token),
        );
  }

  void _handleEvent(SseEvent ev, int token) {
    if (token != _streamToken) return;
    final d = _detail.valueOrNull;
    final result = reduceStreamingEvent(
      detail: d,
      snapshot: _streaming,
      event: ev,
      appL10nInvalidPermission: appL10n.invalidPermissionRequest(''),
      appL10nFailedPermission: appL10n.failedToDecodePermissionRequest,
      appL10nInvalidAsk: appL10n.invalidAskRequest,
      appL10nFailedAsk: appL10n.failedToDecodeAskRequest,
    );
    _streaming = result.snapshot;
    _lastRunStatus = _statusFromPhase(result.snapshot.phase);
    if (result.detail != null && result.detail != d) {
      _detail = AsyncValue.ready(result.detail!);
    }

    if (ev.event == 'user_message') {
      composerText = '';
      attachments.clear();
    }

    _emit();

    if (ev.event == 'done') {
      debugPrint('[notify] SSE done event: thread=$threadId token=$token');
      _cancelStream();
      _finishStream(phase: StreamPhase.completed);
      refreshTail();
    } else if (ev.event == 'error') {
      debugPrint('[notify] SSE error event: thread=$threadId token=$token data=${ev.data}');
      _cancelStream();
      _finishStream(
        phase: StreamPhase.failed,
        error: ev.data.isNotEmpty ? ev.data : null,
      );
      refreshTail();
    } else if (ev.event == 'stopped') {
      debugPrint('[notify] SSE stopped event: thread=$threadId token=$token');
      _cancelStream();
      _refreshThreadsList();
      _refreshTailAfterStop();
    }
  }

  /// Poll refreshTail until the persisted partial message appears, then
  /// clear the streaming snapshot. The backend persists the partial output
  /// asynchronously after graceful ACP cancellation, so the message may not
  /// be in the database yet when the stopped event fires.
  Future<void> _refreshTailAfterStop() async {
    for (var i = 0; i < 20; i++) {
      await Future.delayed(const Duration(milliseconds: 200));
      if (_status == ThreadStoreStatus.deleted) return;
      final d = _detail.valueOrNull;
      if (d == null || d.messages.isEmpty) continue;
      final newestId = d.messages.last.id;
      if (newestId == null) continue;
      try {
        final tail = await api.getThreadMessages(threadId, afterId: newestId);
        if (tail.isNotEmpty) {
          _detail = AsyncValue.ready(d.copyWith(
            messages: [...d.messages, ...tail],
            totalMessages: d.totalMessages + tail.length,
          ));
          _clearStreamingState();
          _emit();
          return;
        }
      } catch (_) {
        // keep polling
      }
    }
    // Timed out — clear streaming state anyway so the UI doesn't freeze.
    _clearStreamingState();
    _emit();
  }

  void _handleStreamError(Object e, int token) {
    debugPrint('[notify] stream error: thread=$threadId token=$token streamToken=$_streamToken error=$e');
    if (token != _streamToken) return;
    if (e is ApiException && e.statusCode == 409) {
      // Another client is running this thread; try to resume the existing run.
      resume();
      return;
    }
    _finishStream(error: '$e', phase: StreamPhase.failed);
  }

  void _handleStreamDone(int token) {
    debugPrint('[notify] stream done: thread=$threadId token=$token streamToken=$_streamToken isActive=${_streaming.isActive}');
    if (token != _streamToken) return;
    // Stream closed without an explicit done/error event. Finish the stream
    // so the UI and notification callback are updated.
    if (_streaming.isActive) {
      _finishStream(phase: StreamPhase.completed);
    }
  }

  bool _runFinishedFired = false;

  void _finishStream({
    StreamPhase phase = StreamPhase.completed,
    String? error,
  }) {
    _streaming = _streaming.copyWith(
      phase: phase,
      parts: [],
      thinkingActive: false,
      lastSeq: 0,
      clearPendingPermission: true,
      clearPendingAsk: true,
      clearStartedAt: true,
      error: error,
      clearError: error == null,
    );
    _lastRunStatus = _statusFromPhase(phase);
    _emit();
    if (!_runFinishedFired &&
        (phase == StreamPhase.completed || phase == StreamPhase.failed)) {
      _runFinishedFired = true;
      debugPrint('[notify] onRunFinished: thread=$threadId phase=$phase failed=${phase == StreamPhase.failed}');
      onRunFinished?.call(phase == StreamPhase.failed);
    } else {
      debugPrint('[notify] _finishStream skipped onRunFinished: thread=$threadId alreadyFired=$_runFinishedFired phase=$phase');
    }
  }

  void _finishResume(Map<String, dynamic> run) {
    final status = run['status'] as String? ?? 'idle';
    _lastRunStatus = status;
    _streaming = StreamingSnapshot.empty.copyWith(
      phase: phaseForStatus(status),
      error: status == 'failed' ? run['error'] as String? : null,
      startedAt: run['started_at'] as String?,
    );
    _emit();
  }

  String? _statusFromPhase(StreamPhase phase) {
    return switch (phase) {
      StreamPhase.running => 'running',
      StreamPhase.completed => 'completed',
      StreamPhase.stopped => 'stopped',
      StreamPhase.failed => 'failed',
      _ => null,
    };
  }

  void _refreshThreadsList() {
    // Keep the thread list in sync without awaiting.
    unawaited(api.listThreads().then((_) {}, onError: (_) {}));
  }
}
