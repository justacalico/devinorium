import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../api/api_client.dart';
import '../api/api_service.dart';
import '../l10n/global_l10n.dart';
import '../models/composer_mode.dart';
import '../models/models.dart';
import '../utils/debug_log.dart';
import 'async_value.dart';
import 'command_scheduler.dart';
import 'streaming_reducer.dart';
import 'streaming_state.dart';

/// Lifecycle status for an individual thread store.
enum ThreadStoreStatus { empty, loading, ready, error, deleted }

/// Composer snapshot saved while a message is in flight so the prompt and
/// attachments can be restored if the turn fails before acknowledgement.
class _PendingSend {
  final String prompt;
  final String composerText;
  final List<({String filename, String mime, Uint8List bytes})> attachments;
  final String clientMessageId;
  final ComposerMode composerMode;

  _PendingSend({
    required this.prompt,
    required this.composerText,
    required this.attachments,
    required this.clientMessageId,
    required this.composerMode,
  });
}

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

  // Optimistic messages that have been cleared from the composer but not yet
  // echoed back by the server. Kept separate from the persisted detail so paging
  // and tail refreshes never confuse them with real rows.
  final List<Message> _optimisticMessages = [];

  /// Snapshot of the composer at send time so we can restore it if the turn
  /// fails before the server acknowledges the user message.
  _PendingSend? _pendingSend;

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

  /// The persisted detail merged with any optimistic user messages that have
  /// not yet been echoed back by the server. This is the view the UI should
  /// render; callers that need the raw persisted list should use [detail].
  ThreadDetail? get displayDetail {
    final d = _detail.valueOrNull;
    if (d == null || _optimisticMessages.isEmpty) return d;
    final serverIds = <String>{
      for (final m in d.messages)
        if (m.clientMessageId != null) m.clientMessageId!,
    };
    final pending = _optimisticMessages
        .where(
          (m) =>
              m.clientMessageId != null &&
              !serverIds.contains(m.clientMessageId),
        )
        .toList();
    if (pending.isEmpty) return d;
    return d.copyWith(messages: [...d.messages, ...pending]);
  }

  StreamingSnapshot get streaming => _streaming;
  String get globalError => _globalError;
  String? get lastRunStatus => _lastRunStatus;

  bool get sending => _streaming.isActive;
  List<MessagePart> get streamingParts => _streaming.parts;
  bool get streamingThinkingActive => _streaming.thinkingActive;
  PermissionRequest? get pendingPermissionRequest =>
      _streaming.pendingPermission;
  AskRequest? get pendingAskRequest => _streaming.pendingAsk;
  Plan? get plan =>
      _streaming.isActive ? _streaming.plan : _detail.valueOrNull?.plan;
  String? get startedAt => _streaming.startedAt;

  /// Load the persisted detail and, if the server says the thread is still
  /// running, resume the live stream. This is t3code's "snapshot then
  /// subscribe" pattern.
  ///
  /// The thread metadata is fetched first so the UI can render instantly; the
  /// initial message page is then loaded in the background.
  Future<void> load() async {
    _status = ThreadStoreStatus.loading;
    _emit();
    try {
      final [detail, run] = await Future.wait([
        api.getThread(threadId, includeMessages: false),
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
      unawaited(_loadInitialMessages());
    } catch (e) {
      debugLogFailure('thread.load', e, threadId: threadId);
      _status = ThreadStoreStatus.error;
      _globalError = '$e';
      _emit();
    }
  }

  /// Explicitly refresh the persisted detail without touching the stream.
  Future<void> reloadDetail() async {
    try {
      final d = await api.getThread(threadId, includeMessages: false);
      _detail = AsyncValue.ready(d);
      _globalError = '';
      _emit();
      unawaited(_loadInitialMessages());
    } catch (e) {
      debugLogFailure('thread.reloadDetail', e, threadId: threadId);
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

        // Fetch metadata if we don't have it yet (e.g. resumeThread).
        if (_detail.valueOrNull == null) {
          try {
            final d = await api.getThread(threadId, includeMessages: false);
            _detail = AsyncValue.ready(d);
            selectedModel = d.thread.model;
            selectedPermission = d.thread.permissionMode;
            _status = ThreadStoreStatus.ready;
            _globalError = '';
            _emit();
          } catch (e) {
            debugLogFailure('thread.resume.loadDetail', e, threadId: threadId);
            _globalError = '$e';
            _emit();
            return;
          }
        }

        _applyRunSnapshot(run);
        _lastRunStatus = run['status'] as String?;
        if (_lastRunStatus == 'running') {
          _runFinishedFired = false;
          _startStream(_nextStreamToken());
          unawaited(_loadInitialMessages());
        } else {
          _finishResume(run);
          await reloadDetail();
        }
      } catch (e) {
        debugLogFailure('thread.resume', e, threadId: threadId);
        _globalError = '$e';
        _emit();
      }
    });
  }

  /// Send a user message and start a new streaming turn.
  Future<void> sendMessage() async {
    final prompt = _promptForMode(composerText.trim());
    if (prompt.isEmpty) return;
    if (_pendingSend != null) return;
    _globalError = '';

    await _scheduler.run('stream', () async {
      final token = _nextStreamToken();
      try {
        await saveSettings();
      } catch (_) {
        return;
      }
      if (token != _streamToken || onStateChanged == null) return;

      final messageAttachments =
          List<({String filename, String mime, Uint8List bytes})>.of(
            attachments,
          );
      final clientMessageId = _newClientMessageId();

      // Snapshot the composer so we can restore it if the turn fails before the
      // server acknowledges the user message.
      _pendingSend = _PendingSend(
        prompt: prompt,
        composerText: composerText,
        attachments: messageAttachments,
        clientMessageId: clientMessageId,
        composerMode: composerMode,
      );

      // Clear the composer and show the message immediately, like t3code does.
      // The message is removed once the server echoes the same client id.
      composerText = '';
      attachments.clear();
      _optimisticMessages.add(
        _buildOptimisticMessage(prompt, messageAttachments, clientMessageId),
      );
      _emit();

      _clearStreamingState();
      _streaming = _streaming.copyWith(phase: StreamPhase.sending);
      _lastRunStatus = 'running';
      _runFinishedFired = false;
      // Each turn owns its own plan; don't show a stale plan from a previous
      // turn while waiting for the model to emit a new one.
      if (_detail.valueOrNull != null) {
        _detail = AsyncValue.ready(
          _detail.valueOrNull!.copyWith(clearPlan: true),
        );
      }
      _emit();

      try {
        _subscription = api
            .sendMessageStream(
              threadId: threadId,
              prompt: prompt,
              mode: composerMode.name,
              clientMessageId: clientMessageId,
              attachments: messageAttachments,
            )
            .listen(
              (ev) => _handleEvent(ev, token),
              onError: (e) => _handleStreamError(e, token),
              onDone: () => _handleStreamDone(token),
            );
      } catch (e) {
        debugLogFailure('thread.sendMessage.listen', e, threadId: threadId);
        _finishStream(error: '$e', phase: StreamPhase.failed);
      }
    });
  }

  /// Persist the selected model and permission mode for this thread.
  /// Only fetches the persisted detail when the local detail has never been
  /// loaded, so sending a message does not flash an empty thread and race the
  /// incoming stream events.
  Future<void> saveSettings() async {
    try {
      await api.updateThreadSettings(
        threadId,
        model: selectedModel.isEmpty ? null : selectedModel,
        permissionMode: selectedPermission,
      );
      if (_detail.isEmpty) {
        await reloadDetail();
      }
    } catch (e) {
      debugLogFailure('thread.saveSettings', e, threadId: threadId);
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
        debugLogFailure('thread.stop', e, threadId: threadId);
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
        debugLogFailure('thread.respondPermission', e, threadId: threadId);
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
        debugLogFailure('thread.respondAsk', e, threadId: threadId);
        _globalError = '$e';
        _emit();
      }
    });
  }

  /// Load the next page of older messages.
  Future<void> loadMoreMessages() async {
    final d = _detail.valueOrNull;
    if (d == null) return;
    if (d.hasMore == false) return;
    if (d.hasMore == null &&
        d.messages.isNotEmpty &&
        d.messages.length >= d.totalMessages) {
      return;
    }
    if (d.messages.isEmpty) {
      if (d.totalMessages > 0) {
        await _loadInitialMessages();
      }
      return;
    }

    try {
      final MessagePage page;
      if (d.beforeCursor != null) {
        page = await api.getThreadMessages(
          threadId,
          beforeCursor: d.beforeCursor,
          turnLimit: d.turnLimit ?? 50,
        );
      } else {
        final oldestId = d.messages.first.id;
        if (oldestId == null) return;
        page = await api.getThreadMessages(
          threadId,
          beforeId: oldestId,
          limit: 50,
        );
      }
      if (page.messages.isEmpty) {
        if (d.hasMore != false) {
          _detail = AsyncValue.ready(d.copyWith(hasMore: false));
          _emit();
        }
        return;
      }
      _detail = AsyncValue.ready(
        d.copyWith(
          messages: [...page.messages, ...d.messages],
          totalMessages: page.total > d.totalMessages
              ? page.total
              : d.totalMessages,
          beforeCursor: page.beforeCursor,
          hasMore: page.hasMore,
          turnLimit: page.turnLimit ?? d.turnLimit,
          rawCount: page.rawCount,
        ),
      );
      _emit();
    } catch (e) {
      debugLogFailure('thread.loadMoreMessages', e, threadId: threadId);
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
      final page = await api.getThreadMessages(
        threadId,
        afterId: newestId,
        limit: 50,
      );
      if (page.messages.isNotEmpty) {
        final total = page.total > 0
            ? page.total
            : d.totalMessages + page.messages.length;
        _detail = AsyncValue.ready(
          d.copyWith(
            messages: [...d.messages, ...page.messages],
            totalMessages: total,
          ),
        );
        _emit();
      }
    } catch (e) {
      debugLogFailure('thread.refreshTail', e, threadId: threadId);
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
    _subscription = api
        .watchThreadEvents(threadId)
        .listen(
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
      final msg = parseSseMessage(ev.data);
      if (msg?.clientMessageId != null) {
        _removeOptimisticMessage(msg!.clientMessageId!);
      } else if (msg != null) {
        // Fallback for servers that do not echo the client id yet: match by
        // role and content and remove only the first duplicate.
        final idx = _optimisticMessages.indexWhere(
          (m) => m.role == msg.role && m.content == msg.content,
        );
        if (idx != -1) {
          _optimisticMessages.removeAt(idx);
        }
      }
    }

    _emit();

    if (ev.event == 'done') {
      _cancelStream();
      _finishStream(phase: StreamPhase.completed);
      refreshTail();
    } else if (ev.event == 'error') {
      _cancelStream();
      debugLogFailure(
        'thread.stream.event',
        ev.data.isNotEmpty ? ev.data : 'error event',
        threadId: threadId,
      );
      _finishStream(
        phase: StreamPhase.failed,
        error: ev.data.isNotEmpty ? ev.data : null,
      );
      refreshTail();
    } else if (ev.event == 'stopped') {
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
        final page = await api.getThreadMessages(
          threadId,
          afterId: newestId,
          limit: 50,
        );
        if (page.messages.isNotEmpty) {
          final total = page.total > 0
              ? page.total
              : d.totalMessages + page.messages.length;
          _detail = AsyncValue.ready(
            d.copyWith(
              messages: [...d.messages, ...page.messages],
              totalMessages: total,
            ),
          );
          _clearStreamingState();
          _emit();
          return;
        }
      } catch (e) {
        debugLogFailure('thread.stop.refreshTail', e, threadId: threadId);
        // keep polling
      }
    }
    // Timed out — clear streaming state anyway so the UI doesn't freeze.
    _clearStreamingState();
    _emit();
  }

  void _handleStreamError(Object e, int token) {
    if (token != _streamToken) return;
    if (e is ApiException && e.statusCode == 409) {
      // Another client is running this thread; restore our composer and then
      // try to resume the existing run so the user can see what's happening.
      _restorePendingSend();
      _emit();
      unawaited(resume());
      return;
    }
    debugLogFailure('thread.stream', e, threadId: threadId);
    _finishStream(error: '$e', phase: StreamPhase.failed);
  }

  void _handleStreamDone(int token) {
    if (token != _streamToken) return;
    // Stream closed without an explicit done/error event. If we are still
    // waiting for a user message acknowledgement, treat it as a failure and
    // restore the composer so the user can retry.
    if (_pendingSend != null) {
      debugLogFailure('thread.stream.done', appL10n.connectionFailed, threadId: threadId);
      _finishStream(phase: StreamPhase.failed, error: appL10n.connectionFailed);
      return;
    }
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
    // Persist the final streaming plan into the persisted detail so the
    // sidebar stays in sync once the stream ends.
    if (_detail.valueOrNull != null) {
      _detail = AsyncValue.ready(
        _detail.valueOrNull!.copyWith(
          plan: _streaming.plan,
          clearPlan: _streaming.plan == null,
        ),
      );
    }
    if (phase == StreamPhase.failed) {
      _restorePendingSend();
    } else if (_optimisticMessages.isNotEmpty) {
      // The turn ended successfully but a stray optimistic message remains;
      // drop it rather than showing a duplicate.
      _optimisticMessages.clear();
      _pendingSend = null;
    }
    _lastRunStatus = _statusFromPhase(phase);
    _emit();
    if (!_runFinishedFired &&
        (phase == StreamPhase.completed || phase == StreamPhase.failed)) {
      _runFinishedFired = true;
      onRunFinished?.call(phase == StreamPhase.failed);
    }
  }

  void _finishResume(Map<String, dynamic> run) {
    final status = run['status'] as String? ?? 'idle';
    _lastRunStatus = status;
    _status = ThreadStoreStatus.ready;
    _streaming = StreamingSnapshot.empty.copyWith(
      phase: phaseForStatus(status),
      error: status == 'failed' ? run['error'] as String? : null,
      startedAt: run['started_at'] as String?,
    );
    _emit();
  }

  /// Load the first page of messages when the detail is ready but empty.
  Future<void> _loadInitialMessages() async {
    final d = _detail.valueOrNull;
    if (d == null || d.totalMessages == 0 || d.messages.isNotEmpty) return;
    try {
      final page = await api.getThreadMessages(threadId, turnLimit: 50);
      if (page.messages.isNotEmpty) {
        _detail = AsyncValue.ready(
          d.copyWith(
            messages: page.messages,
            totalMessages: page.total > d.totalMessages
                ? page.total
                : d.totalMessages,
            beforeCursor: page.beforeCursor,
            hasMore: page.hasMore,
            turnLimit: page.turnLimit ?? 50,
            rawCount: page.rawCount,
          ),
        );
        _globalError = '';
        _emit();
      }
    } catch (e) {
      debugLogFailure('thread.loadInitialMessages', e, threadId: threadId);
      _globalError = '$e';
      _emit();
    }
  }

  final _random = Random.secure();

  String _newClientMessageId() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final rnd = _random.nextInt(0x7fffffff);
    return 'cm-$now-$rnd';
  }

  Message _buildOptimisticMessage(
    String prompt,
    List<({String filename, String mime, Uint8List bytes})> attachments,
    String clientMessageId,
  ) {
    return Message(
      role: 'user',
      content: prompt,
      clientMessageId: clientMessageId,
      attachments: attachments
          .map((a) => Attachment(filename: a.filename, size: a.bytes.length))
          .toList(),
    );
  }

  void _removeOptimisticMessage(String clientMessageId) {
    _optimisticMessages.removeWhere(
      (m) => m.clientMessageId == clientMessageId,
    );
    if (_pendingSend?.clientMessageId == clientMessageId) {
      _pendingSend = null;
    }
  }

  void _restorePendingSend() {
    final pending = _pendingSend;
    if (pending == null) {
      _optimisticMessages.clear();
      return;
    }
    composerText = pending.composerText;
    attachments
      ..clear()
      ..addAll(pending.attachments);
    composerMode = pending.composerMode;
    _optimisticMessages.removeWhere(
      (m) => m.clientMessageId == pending.clientMessageId,
    );
    _pendingSend = null;
    _globalError = '';
  }

  String _promptForMode(String prompt) {
    if (composerMode != ComposerMode.ask) return prompt;
    return stripAskPrefix(prompt);
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
