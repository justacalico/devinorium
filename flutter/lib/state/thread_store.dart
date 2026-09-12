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
  final List<PathRef> pathRefs;
  final List<ThreadReference> threadReferences;
  final String clientMessageId;
  final ComposerMode composerMode;

  /// True when the pending send is an edit-and-resend. On failure the
  /// edited text only goes back into the composer if it is empty; a draft
  /// the user typed meanwhile is never clobbered.
  final bool resendEdit;

  _PendingSend({
    required this.prompt,
    required this.composerText,
    required this.attachments,
    required this.pathRefs,
    required this.threadReferences,
    required this.clientMessageId,
    required this.composerMode,
    this.resendEdit = false,
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
    List<PathRef>? pathRefs,
    List<ThreadReference>? threadReferences,
    ComposerMode? composerMode,
    String? selectedModel,
    String? selectedReasoning,
    String? selectedPermission,
    String? selectedProvider,
    String? lastRunStatus,
  }) : _status = status ?? ThreadStoreStatus.empty,
       _detail = detail ?? const AsyncValue.empty(),
       _streaming = streaming ?? StreamingSnapshot.empty,
       composerText = composerText ?? '',
       attachments = attachments == null ? [] : List.of(attachments),
       pathRefs = pathRefs == null ? [] : List.of(pathRefs),
       threadReferences =
           threadReferences == null ? [] : List.of(threadReferences),
       composerMode = composerMode ?? ComposerMode.code,
       selectedModel = selectedModel ?? '',
       selectedReasoning = selectedReasoning ?? '',
       selectedPermission = selectedPermission ?? 'normal',
       selectedProvider = selectedProvider ?? '' {
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
  // Reassigned rather than mutated so Selector-based widgets see a new list.
  List<({String filename, String mime, Uint8List bytes})> attachments;
  List<PathRef> pathRefs;
  List<ThreadReference> threadReferences;
  ComposerMode composerMode;
  String selectedModel;
  String selectedReasoning;
  String selectedPermission;
  String selectedProvider;

  // Optimistic messages that have been cleared from the composer but not yet
  // echoed back by the server. Kept separate from the persisted detail so paging
  // and tail refreshes never confuse them with real rows.
  final List<Message> _optimisticMessages = [];

  /// Snapshot of the composer at send time so we can restore it if the turn
  /// fails before the server acknowledges the user message.
  _PendingSend? _pendingSend;

  // Pending resend truncation: the server deletes the anchor and everything
  // after it when the run starts, so the rows stay visible until the stream
  // acknowledges the run with its first committed event.
  int? _resendAnchorId;
  bool _resendInclusive = false;

  // Stream lifecycle.
  StreamSubscription? _subscription;
  int _streamToken = 0;

  // Keys from _editedFileEntries already reported through onAgentEditedFiles,
  // so part_update refreshes of the same tool call don't fire again.
  final Set<String> _seenEditedFiles = {};

  // In-flight initial message load so callers can await the same request.
  Future<void>? _initialMessagesFuture;

  // Throttle stream event notifications so a rapid burst of part events does
  // not force the UI to rebuild on every single frame.
  Timer? _emitTimer;
  bool _emitPending = false;
  static const _emitThrottle = Duration(milliseconds: 50);

  // t3code-style serial command queue for this thread.
  final ThreadCommandScheduler _scheduler = ThreadCommandScheduler();

  /// Called whenever any piece of thread state changes.
  VoidCallback? onStateChanged;

  /// Called when the thread metadata is updated by the server, so the global
  /// thread list can be kept in sync without waiting for a full refresh.
  void Function(Thread thread)? onThreadUpdated;

  /// Called when a run finishes (completed or failed). The [failed] flag
  /// indicates whether the run ended with an error.
  void Function(bool failed)? onRunFinished;

  /// Called when a tool call in the live stream reports files it edited.
  /// Each (tool call, path) pair fires once; a later tool call touching the
  /// same file fires again.
  void Function(List<String> paths)? onAgentEditedFiles;

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
  int get streamingDigest => _streaming.digest;
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
      selectedReasoning = d.thread.reasoningEffort;
      selectedPermission = d.thread.permissionMode;
      selectedProvider = d.thread.providerId;
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

  /// Explicitly refresh the persisted thread metadata without touching the
  /// stream. The fetched detail carries no messages (see [includeMessages]),
  /// so we merge its fresh metadata into the existing detail instead of
  /// replacing it wholesale. Replacing it would briefly wipe the loaded
  /// messages and paging cursors, causing the thread view to flicker while
  /// the first page is reloaded.
  Future<void> reloadDetail() async {
    try {
      final fresh = await api.getThread(threadId, includeMessages: false);
      final current = _detail.valueOrNull;
      if (current != null && current.messages.isNotEmpty) {
        // Merge fresh metadata into the existing detail, keeping the loaded
        // messages and paging cursors intact so the view does not flicker.
        _detail = AsyncValue.ready(
          current.copyWith(
            thread: fresh.thread,
            totalMessages: fresh.totalMessages,
            plan: fresh.plan,
            clearPlan: fresh.plan == null,
          ),
        );
      } else {
        // No messages loaded yet: adopt the fresh detail and load the first
        // page in the background.
        _detail = AsyncValue.ready(
          current != null
              ? current.copyWith(
                  thread: fresh.thread,
                  totalMessages: fresh.totalMessages,
                  plan: fresh.plan,
                  clearPlan: fresh.plan == null,
                )
              : fresh,
        );
        unawaited(_loadInitialMessages());
      }
      _globalError = '';
      _emit();
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
        var justLoadedDetail = false;
        if (_detail.valueOrNull == null) {
          justLoadedDetail = true;
          try {
            final d = await api.getThread(threadId, includeMessages: false);
            _detail = AsyncValue.ready(d);
            selectedModel = d.thread.model;
            selectedReasoning = d.thread.reasoningEffort;
            selectedPermission = d.thread.permissionMode;
            selectedProvider = d.thread.providerId;
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
          if (justLoadedDetail) {
            // The detail was fetched moments ago; only the first message page
            // is missing, so load it directly instead of refetching metadata.
            unawaited(_loadInitialMessages());
          } else {
            // Refresh metadata without wiping loaded messages, then pull any
            // rows that arrived while we were disconnected. refreshTail
            // appends only newer rows, so the view never flickers.
            final hadMessages =
                _detail.valueOrNull?.messages.isNotEmpty ?? false;
            await reloadDetail();
            if (hadMessages) {
              await refreshTail();
            }
          }
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
    if (prompt.isEmpty && pathRefs.isEmpty && threadReferences.isEmpty) {
      return;
    }
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
      final messagePathRefs = List<PathRef>.of(pathRefs);
      final messageThreadRefs = List<ThreadReference>.of(threadReferences);
      final clientMessageId = _newClientMessageId();

      // Snapshot the composer so we can restore it if the turn fails before the
      // server acknowledges the user message.
      _pendingSend = _PendingSend(
        prompt: prompt,
        composerText: composerText,
        attachments: messageAttachments,
        pathRefs: messagePathRefs,
        threadReferences: messageThreadRefs,
        clientMessageId: clientMessageId,
        composerMode: composerMode,
      );

      // Clear the composer and show the message immediately, like t3code does.
      // The message is removed once the server echoes the same client id.
      composerText = '';
      attachments = [];
      pathRefs = [];
      threadReferences = [];
      _optimisticMessages.add(
        _buildOptimisticMessage(
          prompt,
          messageAttachments,
          messagePathRefs,
          messageThreadRefs,
          clientMessageId,
        ),
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
              contextPaths: messagePathRefs,
              referencedThreadIds: [
                for (final r in messageThreadRefs) r.id,
              ],
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

  /// Edit a user message or regenerate a reply. The server replays the
  /// thread from the turn [message] belongs to: with [editedPrompt] the
  /// stored user message is replaced by the new text, without it the turn's
  /// reply is regenerated.
  Future<void> resendMessage(Message message, {String? editedPrompt}) async {
    final d = _detail.valueOrNull;
    final messageId = message.id;
    if (d == null || messageId == null || _streaming.isActive) return;

    final editing = editedPrompt != null;
    final anchor = editing
        ? (message.role == 'user' ? message : null)
        : _turnAnchor(d.messages, message);
    final anchorId = anchor?.id;
    if (anchor == null || anchorId == null) return;
    _globalError = '';

    await _scheduler.run('stream', () async {
      final token = _nextStreamToken();
      try {
        await saveSettings();
      } catch (_) {
        return;
      }
      if (token != _streamToken || onStateChanged == null) return;

      _resendAnchorId = anchorId;
      _resendInclusive = editing;

      String? clientMessageId;
      if (editing) {
        clientMessageId = _newClientMessageId();
        _pendingSend = _PendingSend(
          prompt: editedPrompt,
          composerText: editedPrompt,
          attachments: const [],
          pathRefs: const [],
          threadReferences: const [],
          clientMessageId: clientMessageId,
          composerMode: composerMode,
          resendEdit: true,
        );
        _optimisticMessages.add(
          _buildOptimisticMessage(
            editedPrompt,
            const [],
            const [],
            const [],
            clientMessageId,
          ),
        );
      }

      _clearStreamingState();
      _streaming = _streaming.copyWith(phase: StreamPhase.sending);
      _lastRunStatus = 'running';
      _runFinishedFired = false;
      if (_detail.valueOrNull != null) {
        _detail = AsyncValue.ready(
          _detail.valueOrNull!.copyWith(clearPlan: true),
        );
      }
      _emit();

      try {
        _subscription = api
            .resendMessageStream(
              threadId: threadId,
              messageId: messageId,
              editedPrompt: editedPrompt,
              mode: composerMode.name,
              clientMessageId: clientMessageId,
            )
            .listen(
              (ev) => _handleEvent(ev, token),
              onError: (e) => _handleStreamError(e, token),
              onDone: () => _handleStreamDone(token),
            );
      } catch (e) {
        debugLogFailure('thread.resendMessage.listen', e, threadId: threadId);
        _resendAnchorId = null;
        _finishStream(error: '$e', phase: StreamPhase.failed);
      }
    });
  }

  /// The user message anchoring the turn [message] belongs to: the latest
  /// user message at or before its position in the list.
  static Message? _turnAnchor(List<Message> messages, Message message) {
    if (message.role == 'user') return message;
    final idx = messages.indexWhere((m) => m.id == message.id);
    if (idx == -1) return null;
    for (var i = idx; i >= 0; i--) {
      if (messages[i].role == 'user') return messages[i];
    }
    return null;
  }

  /// Persist the selected model and permission mode for this thread.
  /// Only fetches the persisted detail when the local detail has never been
  /// loaded, so sending a message does not flash an empty thread and race the
  /// incoming stream events.
  Future<void> saveSettings() async {
    try {
      await api.updateThreadSettings(
        threadId,
        provider: selectedProvider.isEmpty ? null : selectedProvider,
        model: selectedModel.isEmpty ? null : selectedModel,
        permissionMode: selectedPermission,
        reasoningEffort: selectedReasoning,
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

  /// Wait for the first page of messages to load, starting it if necessary.
  Future<void> ensureInitialMessagesLoaded() => _loadInitialMessages();

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
    _flushEmit();
    _cancelStream();
    _emit();
  }

  /// Dispose the store, cancelling any in-flight stream.
  void dispose() {
    _emitTimer?.cancel();
    _emitTimer = null;
    _emitPending = false;
    _cancelStream();
    _scheduler.dispose();
    onStateChanged = null;
    onThreadUpdated = null;
    onRunFinished = null;
    onAgentEditedFiles = null;
    _emit();
  }

  // ---- private ----

  void _emit() {
    onStateChanged?.call();
  }

  void _throttledEmit() {
    _emitPending = true;
    if (_emitTimer != null) return;
    _emitNowAndSchedule();
  }

  void _emitNowAndSchedule() {
    _emitPending = false;
    _emit();
    _emitTimer = Timer(_emitThrottle, () {
      _emitTimer = null;
      if (_emitPending) _emitNowAndSchedule();
    });
  }

  void _flushEmit() {
    _emitTimer?.cancel();
    _emitTimer = null;
    _emitPending = false;
  }

  void _emitNow() {
    _flushEmit();
    _emit();
  }

  void _applyRunSnapshot(Map<String, dynamic> run) {
    _streaming = runSnapshotFromJson(run);
    // Edits already present in the snapshot are marked seen so resuming a
    // run does not fire onAgentEditedFiles for work that already happened.
    _seenEditedFiles
      ..clear()
      ..addAll(_editedFileEntries(_streaming.parts).map((e) => e.key));
    _lastRunStatus = run['status'] as String?;
    _emit();
  }

  void _cancelStream() {
    _streamToken += 1;
    _subscription?.cancel();
    _subscription = null;
    _resendAnchorId = null;
  }

  void _clearStreamingState() {
    _streaming = StreamingSnapshot.empty;
    _seenEditedFiles.clear();
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
    // A resend on another client deleted this thread's tail server-side;
    // resync the loaded window instead of keeping ghost rows around.
    if (ev.event == 'messages_truncated') {
      unawaited(_resyncMessages());
      return;
    }
    var d = _detail.valueOrNull;
    // A resend deletes the tail server-side when the run starts; mirror that
    // here once the stream's first committed event arrives so a request that
    // was rejected before the run started never touches the list.
    if (_resendAnchorId != null &&
        (ev.event == 'user_message' ||
            ev.event == 'done' ||
            ev.event == 'error' ||
            ev.event == 'stopped')) {
      d = _truncateForResend(d);
    }
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

    if (ev.event == 'thread_update') {
      final updated = _detail.valueOrNull?.thread;
      final previous = d?.thread;
      // Notify the thread list whenever the thread metadata actually
      // changed, including git/worktree updates, so the sidebar stays in
      // sync without a full refresh.
      if (updated != null && (previous == null || updated != previous)) {
        onThreadUpdated?.call(updated);
      }
    }

    if (ev.event == 'user_message') {
      final msg = parseSseMessage(ev.data);
      if (msg != null) {
        _mergeOptimisticAttachmentBytes(msg);
      }
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
          // The send was acknowledged, so release the pending snapshot;
          // otherwise the stream's end would be mistaken for a failure.
          _pendingSend = null;
        }
      }
    }

    // Stream events that only update parts/metadata can be throttled so rapid
    // model output does not force a frame-by-frame rebuild. Anything that
    // creates, completes, or interrupts a turn (or shows a permission/ask
    // prompt) must be emitted immediately so the UI never misses it.
    switch (ev.event) {
      case 'part':
      case 'part_update':
      case 'plan_update':
      case 'thread_update':
        _throttledEmit();
        break;
      case 'state':
      case 'user_message':
      case 'permission_request':
      case 'ask_request':
        _emitNow();
        break;
      case 'done':
      case 'error':
      case 'stopped':
        _flushEmit();
        break;
      default:
        _throttledEmit();
    }

    if (ev.event == 'part' ||
        ev.event == 'part_update' ||
        ev.event == 'state') {
      _notifyAgentEditedFiles();
    }

    if (ev.event == 'done') {
      // The persisted message carries the full parts list; scan it so edits
      // whose live part events were dropped still get reported.
      _notifyAgentEditedFiles(parseSseMessage(ev.data)?.parts);
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
      _emit();
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

  /// Drop the tail rows a resend run deleted server-side. Returns the
  /// updated detail so the caller can feed it to the reducer for the event
  /// that triggered the truncation.
  ThreadDetail? _truncateForResend(ThreadDetail? d) {
    final anchor = _resendAnchorId;
    _resendAnchorId = null;
    if (d == null || anchor == null) return d;
    final inclusive = _resendInclusive;
    final kept = d.messages
        .where(
          (m) =>
              m.id == null || (inclusive ? m.id! < anchor : m.id! <= anchor),
        )
        .toList();
    if (kept.length == d.messages.length) return d;
    final next = d.copyWith(
      messages: kept,
      totalMessages: max(
        0,
        d.totalMessages - (d.messages.length - kept.length),
      ),
    );
    _detail = AsyncValue.ready(next);
    return next;
  }

  /// Replace the loaded messages with a fresh tail page. Used when a resend
  /// request may or may not have deleted rows server-side and the local
  /// list can no longer be trusted. A second delayed fetch covers the race
  /// where the stream died before the server's run task committed the
  /// deletion.
  Future<void> _resyncMessages() async {
    for (var attempt = 0; attempt < 2; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
      final d = _detail.valueOrNull;
      if (d == null) return;
      try {
        final page = await api.getThreadMessages(
          threadId,
          turnLimit: d.turnLimit ?? 50,
        );
        final current = _detail.valueOrNull;
        if (current == null || current.thread.id != d.thread.id) return;
        _detail = AsyncValue.ready(
          current.copyWith(
            messages: page.messages,
            totalMessages: page.total,
            beforeCursor: page.beforeCursor,
            hasMore: page.hasMore,
            turnLimit: page.turnLimit ?? current.turnLimit,
            rawCount: page.rawCount,
          ),
        );
        _emit();
      } catch (e) {
        debugLogFailure('thread.resyncMessages', e, threadId: threadId);
        return;
      }
    }
  }

  void _handleStreamError(Object e, int token) {
    if (token != _streamToken) return;
    if (_resendAnchorId != null) {
      _resendAnchorId = null;
      if (e is! ApiException || e.statusCode < 400 || e.statusCode >= 500) {
        // Not a clean rejection: the run may have started and deleted rows
        // before the connection dropped, so resync rather than trusting the
        // local tail.
        unawaited(_resyncMessages());
      }
    }
    if (e is ApiException && e.statusCode == 409) {
      // Another client is running this thread; restore our composer and then
      // try to resume the existing run so the user can see what's happening.
      // The stream still emits onDone after this error; dropping the phase
      // to idle keeps that from reporting a spurious "completed".
      _restorePendingSend();
      _streaming = _streaming.copyWith(phase: StreamPhase.idle);
      _lastRunStatus = null;
      _emit();
      unawaited(resume());
      return;
    }
    debugLogFailure('thread.stream', e, threadId: threadId);
    _finishStream(error: '$e', phase: StreamPhase.failed);
  }

  void _handleStreamDone(int token) {
    if (token != _streamToken) return;
    if (_resendAnchorId != null) {
      // The stream closed before the run was acknowledged; the tail may
      // have been deleted anyway.
      _resendAnchorId = null;
      unawaited(_resyncMessages());
    }
    // Stream closed without an explicit done/error event. If we are still
    // waiting for a user message acknowledgement, treat it as a failure and
    // restore the composer so the user can retry.
    if (_pendingSend != null) {
      debugLogFailure(
        'thread.stream.done',
        appL10n.connectionFailed,
        threadId: threadId,
      );
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
  Future<void> _loadInitialMessages() {
    if (_initialMessagesFuture != null) return _initialMessagesFuture!;

    final d = _detail.valueOrNull;
    if (d == null || d.totalMessages == 0 || d.messages.isNotEmpty) {
      return Future<void>.value();
    }

    _initialMessagesFuture = _fetchInitialMessages().whenComplete(
      () => _initialMessagesFuture = null,
    );
    return _initialMessagesFuture!;
  }

  Future<void> _fetchInitialMessages() async {
    final current = _detail.valueOrNull;
    if (current == null) return;
    try {
      final page = await api.getThreadMessages(threadId, turnLimit: 50);
      if (page.messages.isNotEmpty) {
        _detail = AsyncValue.ready(
          current.copyWith(
            messages: page.messages,
            totalMessages: page.total > current.totalMessages
                ? page.total
                : current.totalMessages,
            beforeCursor: page.beforeCursor,
            hasMore: page.hasMore,
            turnLimit: page.turnLimit ?? 50,
            rawCount: page.rawCount,
          ),
        );
      } else {
        // The page is empty; still record the fresh total and pagination
        // state so the UI does not keep asking for the same missing rows.
        _detail = AsyncValue.ready(
          current.copyWith(
            totalMessages: page.total,
            hasMore: page.hasMore ?? false,
          ),
        );
      }
      _globalError = '';
      _emit();
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
    List<PathRef> pathRefs,
    List<ThreadReference> threadReferences,
    String clientMessageId,
  ) {
    return Message(
      role: 'user',
      content: prompt,
      clientMessageId: clientMessageId,
      // Match the backend's att_meta order: uploads, then path refs, then
      // thread references.
      attachments: [
        for (var i = 0; i < attachments.length; i++)
          Attachment(
            filename: attachments[i].filename,
            size: attachments[i].bytes.length,
            mime: attachments[i].mime,
            index: i,
            bytes: attachments[i].bytes,
          ),
        for (final r in pathRefs)
          Attachment(
            filename: r.path,
            size: 0,
            isPathRef: true,
            isDir: r.isDir,
          ),
        for (final r in threadReferences)
          Attachment(filename: r.title, size: 0, isThreadRef: true),
      ],
    );
  }

  /// Copy in-memory attachment bytes from the matching optimistic message
  /// onto the acknowledged server message, keyed by attachment index, so
  /// image thumbnails survive the swap without refetching their blobs.
  void _mergeOptimisticAttachmentBytes(Message msg) {
    final serverAtts = msg.attachments;
    if (serverAtts == null || msg.id == null) return;
    Message? opt;
    if (msg.clientMessageId != null) {
      for (final m in _optimisticMessages) {
        if (m.clientMessageId == msg.clientMessageId) {
          opt = m;
          break;
        }
      }
    } else {
      final idx = _optimisticMessages.indexWhere(
        (m) => m.role == msg.role && m.content == msg.content,
      );
      if (idx != -1) opt = _optimisticMessages[idx];
    }
    final bytesByIndex = <int, Uint8List>{
      for (final a in opt?.attachments ?? const <Attachment>[])
        if (a.index != null && a.bytes != null) a.index!: a.bytes!,
    };
    if (bytesByIndex.isEmpty) return;
    var changed = false;
    final merged = <Attachment>[];
    for (final a in serverAtts) {
      final b = a.index != null && a.bytes == null
          ? bytesByIndex[a.index]
          : null;
      if (b != null) {
        merged.add(a.withBytes(b));
        changed = true;
      } else {
        merged.add(a);
      }
    }
    if (!changed) return;
    final patched = msg.copyWith(attachments: merged);
    final d = _detail.valueOrNull;
    if (d == null) return;
    _detail = AsyncValue.ready(
      d.copyWith(
        messages: [for (final m in d.messages) m.id == msg.id ? patched : m],
      ),
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
    // A resend edit only reclaims the composer when it is empty; the text
    // stays retriable from the original message and a live draft wins.
    if (!pending.resendEdit || composerText.trim().isEmpty) {
      composerText = pending.composerText;
    }
    attachments = List.of(pending.attachments);
    pathRefs = List.of(pending.pathRefs);
    threadReferences = List.of(pending.threadReferences);
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

  void _notifyAgentEditedFiles([List<MessagePart>? parts]) {
    final callback = onAgentEditedFiles;
    if (callback == null) return;
    final paths = <String>[];
    for (final e in _editedFileEntries(parts ?? _streaming.parts)) {
      if (_seenEditedFiles.add(e.key)) paths.add(e.path);
    }
    if (paths.isNotEmpty) callback(paths);
  }

  /// (dedupe key, path) pairs for tool calls that write files. The `edit`
  /// kind is the main signal; providers only attach diffs to writes, so a
  /// non-empty diff list counts as an edit regardless of the reported kind.
  /// The key carries the diff content so a tool call that rewrites the same
  /// file across updates still fires for each new version.
  static Iterable<({String key, String path})> _editedFileEntries(
    List<MessagePart> parts,
  ) sync* {
    for (final part in parts) {
      final tool = part.toolCall;
      if (tool == null) continue;
      if (tool.kind != 'edit' && tool.diffs.isEmpty) continue;
      final keys = <String, String>{};
      for (final path in tool.changedFiles) {
        if (path.isNotEmpty) keys[path] = '${tool.id} $path';
      }
      for (final diff in tool.diffs) {
        if (diff.path.isNotEmpty) {
          keys[diff.path] =
              '${tool.id} ${diff.path} ${diff.newText.hashCode}';
        }
      }
      for (final e in keys.entries) {
        yield (key: e.value, path: e.key);
      }
    }
  }

  String? _statusFromPhase(StreamPhase phase) {
    return switch (phase) {
      StreamPhase.sending => 'running',
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
