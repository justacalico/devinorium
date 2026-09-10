import '../api/api_client.dart';
import '../api/api_service.dart';
import '../models/models.dart';
import 'streaming_state.dart';

/// Result of applying one SSE event to a thread.
///
/// `detail` is non-null when the event changed the persisted message list. The
/// reducer never mutates the input; it returns the updated detail that the
/// caller must assign.
class StreamingReduceResult {
  final ThreadDetail? detail;
  final StreamingSnapshot snapshot;

  const StreamingReduceResult({this.detail, required this.snapshot});
}

/// Pure reducer: turn one SSE event and the current snapshot/detail into the
/// next snapshot and (optionally) a new detail value.
///
/// t3code keeps this kind of logic in `threadReducer.ts`: an event comes in,
/// the current state is copied, and a new state is returned. We mirror that on
/// the client side.
StreamingReduceResult reduceStreamingEvent({
  required ThreadDetail? detail,
  required StreamingSnapshot snapshot,
  required SseEvent event,
  String? appL10nInvalidPermission,
  String? appL10nFailedPermission,
  String? appL10nInvalidAsk,
  String? appL10nFailedAsk,
}) {
  final seq = _parseSeq(event.id);
  if (seq != null && event.event != 'state' && seq <= snapshot.lastSeq) {
    return StreamingReduceResult(detail: detail, snapshot: snapshot);
  }

  switch (event.event) {
    case 'state':
      final decoded = tryDecodeJson(event.data);
      if (decoded == null) {
        return StreamingReduceResult(detail: detail, snapshot: snapshot);
      }
      final status = decoded['status'] as String? ?? 'running';
      final next = _applyRunSnapshot(
        snapshot: snapshot,
        json: decoded,
      ).copyWith(phase: phaseForStatus(status));
      if (status == 'stopped') {
        // Keep parts visible; refreshTail will swap them for the persisted
        // message once the backend finishes saving.
        return StreamingReduceResult(
          detail: detail,
          snapshot: next.copyWith(thinkingActive: false),
        );
      }
      final finished = _finishSnapshot(next);
      return StreamingReduceResult(
        detail: detail,
        snapshot: status == 'completed' || status == 'failed' ? finished : next,
      );

    case 'user_message':
      final msg = parseSseMessage(event.data);
      if (msg == null || detail == null) {
        return StreamingReduceResult(detail: detail, snapshot: snapshot);
      }
      final existing =
          msg.id != null && detail.messages.any((m) => m.id == msg.id);
      final nextMessages = existing
          ? detail.messages.map((m) => m.id == msg.id ? msg : m).toList()
          : [...detail.messages, msg];
      final nextDetail = detail.copyWith(
        messages: nextMessages,
        totalMessages: existing
            ? detail.totalMessages
            : detail.totalMessages + 1,
      );
      return StreamingReduceResult(
        detail: nextDetail,
        snapshot: snapshot
            .copyWith(
              phase: StreamPhase.running,
              clearPendingPermission: true,
              clearPendingAsk: true,
              clearError: true,
              lastSeq: seq ?? snapshot.lastSeq,
              startedAt: DateTime.now().toUtc().toIso8601String(),
            )
            .copyWith(error: null), // clear any prior error
      );

    case 'permission_request':
      final decoded = tryDecodeJson(event.data);
      if (decoded == null) {
        return StreamingReduceResult(detail: detail, snapshot: snapshot);
      }
      try {
        final req = PermissionRequest.fromJson(decoded);
        return StreamingReduceResult(
          detail: detail,
          snapshot: snapshot.copyWith(
            phase: StreamPhase.running,
            pendingPermission: req,
            lastSeq: seq ?? snapshot.lastSeq,
            clearError: true,
          ),
        );
      } catch (e) {
        return StreamingReduceResult(
          detail: detail,
          snapshot: snapshot.copyWith(
            error: appL10nInvalidPermission ?? 'Invalid permission request',
            lastSeq: seq ?? snapshot.lastSeq,
          ),
        );
      }

    case 'ask_request':
      final decoded = tryDecodeJson(event.data);
      if (decoded == null) {
        return StreamingReduceResult(detail: detail, snapshot: snapshot);
      }
      try {
        final req = AskRequest.fromJson(decoded);
        return StreamingReduceResult(
          detail: detail,
          snapshot: snapshot.copyWith(
            phase: StreamPhase.running,
            pendingAsk: req,
            lastSeq: seq ?? snapshot.lastSeq,
            clearError: true,
          ),
        );
      } catch (_) {
        return StreamingReduceResult(
          detail: detail,
          snapshot: snapshot.copyWith(
            error: appL10nFailedAsk ?? 'Invalid ask request',
            lastSeq: seq ?? snapshot.lastSeq,
          ),
        );
      }

    case 'part':
      final decoded = tryDecodeJson(event.data);
      if (decoded == null) {
        return StreamingReduceResult(detail: detail, snapshot: snapshot);
      }
      try {
        final part = MessagePart.fromJson(decoded);
        final next = snapshot.copyWith(
          phase: StreamPhase.running,
          parts: [...snapshot.parts, part],
          lastSeq: seq ?? snapshot.lastSeq,
          clearError: true,
        );
        return StreamingReduceResult(
          detail: detail,
          snapshot: _recomputeThinking(next),
        );
      } catch (_) {
        return StreamingReduceResult(detail: detail, snapshot: snapshot);
      }

    case 'part_update':
      final decoded = tryDecodeJson(event.data);
      if (decoded == null) {
        return StreamingReduceResult(detail: detail, snapshot: snapshot);
      }
      try {
        final part = MessagePart.fromJson(decoded);
        final parts = part.id == null
            ? [...snapshot.parts, part]
            : _updateOrAppend(snapshot.parts, part);
        final next = snapshot.copyWith(
          phase: StreamPhase.running,
          parts: parts,
          lastSeq: seq ?? snapshot.lastSeq,
          clearError: true,
        );
        return StreamingReduceResult(
          detail: detail,
          snapshot: _recomputeThinking(next),
        );
      } catch (_) {
        return StreamingReduceResult(detail: detail, snapshot: snapshot);
      }

    case 'done':
      final msg = parseSseMessage(event.data);
      final nextDetail = (msg != null && detail != null)
          ? detail.copyWith(
              messages: [...detail.messages, msg],
              totalMessages: detail.totalMessages + 1,
            )
          : detail;
      return StreamingReduceResult(
        detail: nextDetail,
        snapshot: _finishSnapshot(
          snapshot.copyWith(
            phase: StreamPhase.completed,
            clearPendingPermission: true,
            clearPendingAsk: true,
            clearError: true,
          ),
        ),
      );

    case 'plan_update':
      final decoded = tryDecodeJson(event.data);
      if (decoded == null) {
        return StreamingReduceResult(detail: detail, snapshot: snapshot);
      }
      try {
        final plan = Plan.fromJson(decoded);
        return StreamingReduceResult(
          detail: detail,
          snapshot: snapshot.copyWith(
            phase: StreamPhase.running,
            plan: plan,
            lastSeq: seq ?? snapshot.lastSeq,
          ),
        );
      } catch (_) {
        return StreamingReduceResult(detail: detail, snapshot: snapshot);
      }

    case 'thread_update':
      final decoded = tryDecodeJson(event.data);
      if (decoded == null || detail == null) {
        return StreamingReduceResult(detail: detail, snapshot: snapshot);
      }
      var nextThread = detail.thread;
      var changed = false;
      final title = decoded['title']?.toString();
      if (title != null && title.isNotEmpty && title != nextThread.title) {
        nextThread = nextThread.copyWith(title: title);
        changed = true;
      }
      final updatedAt = decoded['updated_at']?.toString();
      if (updatedAt != null &&
          updatedAt.isNotEmpty &&
          updatedAt != nextThread.updatedAt) {
        nextThread = nextThread.copyWith(updatedAt: updatedAt);
        changed = true;
      }
      if (decoded.containsKey('env_mode')) {
        final raw = decoded['env_mode'];
        if (raw is String && raw != nextThread.envMode) {
          nextThread = nextThread.copyWith(envMode: raw);
          changed = true;
        }
      }
      if (decoded.containsKey('branch')) {
        final raw = decoded['branch'];
        if ((raw == null || raw is String) && raw != nextThread.branch) {
          nextThread = nextThread.copyWith(branch: raw as String?);
          changed = true;
        }
      }
      if (decoded.containsKey('worktree_path')) {
        final raw = decoded['worktree_path'];
        if ((raw == null || raw is String) && raw != nextThread.worktreePath) {
          nextThread = nextThread.copyWith(worktreePath: raw as String?);
          changed = true;
        }
      }
      if (decoded.containsKey('linked_mr')) {
        final raw = decoded['linked_mr'];
        if (raw == null) {
          if (nextThread.linkedMr != null) {
            nextThread = nextThread.copyWith(linkedMrOrNull: null);
            changed = true;
          }
        } else if (raw is Map<String, dynamic>) {
          try {
            final ref = LinkedMergeRequestRef.fromJson(raw);
            if (ref != nextThread.linkedMr) {
              nextThread = nextThread.copyWith(linkedMr: ref);
              changed = true;
            }
          } catch (_) {}
        }
      }
      if (!changed) {
        return StreamingReduceResult(
          detail: detail,
          snapshot: snapshot.copyWith(lastSeq: seq ?? snapshot.lastSeq),
        );
      }
      return StreamingReduceResult(
        detail: detail.copyWith(thread: nextThread),
        snapshot: snapshot.copyWith(lastSeq: seq ?? snapshot.lastSeq),
      );

    case 'stopped':
      // Keep streaming parts visible so the user doesn't see the partial
      // output vanish while the backend persists it. refreshTail() will
      // poll until the persisted message appears, then clear the snapshot.
      return StreamingReduceResult(
        detail: detail,
        snapshot: snapshot.copyWith(
          phase: StreamPhase.stopped,
          thinkingActive: false,
          clearPendingPermission: true,
          clearPendingAsk: true,
          clearError: true,
        ),
      );

    case 'error':
      return StreamingReduceResult(
        detail: detail,
        snapshot: _finishSnapshot(
          snapshot.copyWith(phase: StreamPhase.failed, error: event.data),
        ),
      );
  }

  return StreamingReduceResult(detail: detail, snapshot: snapshot);
}

/// Build a snapshot from a `getThreadRun` response.
StreamingSnapshot runSnapshotFromJson(Map<String, dynamic> json) {
  final status = json['status'] as String?;
  final base = _applyRunSnapshot(snapshot: StreamingSnapshot.empty, json: json);
  if (status == null) return base;
  return base.copyWith(phase: phaseForStatus(status));
}

StreamingSnapshot _applyRunSnapshot({
  required StreamingSnapshot snapshot,
  required Map<String, dynamic> json,
}) {
  final parts = <MessagePart>[];
  final rawParts = json['parts'] as List<dynamic>? ?? [];
  for (final p in rawParts) {
    if (p is! Map<String, dynamic>) continue;
    try {
      parts.add(MessagePart.fromJson(p));
    } catch (_) {}
  }

  final permission = json['permission_request'];
  PermissionRequest? pendingPermission;
  if (permission is Map<String, dynamic>) {
    try {
      pendingPermission = PermissionRequest.fromJson(permission);
    } catch (_) {}
  }

  final ask = json['ask_request'];
  AskRequest? pendingAsk;
  if (ask is Map<String, dynamic>) {
    try {
      pendingAsk = AskRequest.fromJson(ask);
    } catch (_) {}
  }

  Plan? plan;
  final planJson = json['plan'];
  if (planJson is Map<String, dynamic>) {
    try {
      plan = Plan.fromJson(planJson);
    } catch (_) {}
  }
  final error = json['error'] as String?;

  return snapshot.copyWith(
    parts: parts,
    thinkingActive: json['thinking_active'] as bool? ?? false,
    lastSeq: (json['last_seq'] as num?)?.toInt() ?? snapshot.lastSeq,
    pendingPermission: pendingPermission,
    clearPendingPermission: pendingPermission == null,
    pendingAsk: pendingAsk,
    clearPendingAsk: pendingAsk == null,
    plan: plan,
    clearPlan: plan == null,
    error: error,
    clearError: error == null,
    startedAt: json['started_at'] as String?,
  );
}

List<MessagePart> _updateOrAppend(List<MessagePart> parts, MessagePart part) {
  final idx = parts.indexWhere((p) => p.id == part.id);
  if (idx >= 0) {
    final next = List<MessagePart>.of(parts);
    next[idx] = part;
    return next;
  }
  return [...parts, part];
}

StreamingSnapshot _recomputeThinking(StreamingSnapshot snapshot) {
  return snapshot.copyWith(
    thinkingActive:
        snapshot.parts.isNotEmpty && snapshot.parts.last.type == 'thinking',
  );
}

StreamingSnapshot _finishSnapshot(StreamingSnapshot snapshot) {
  return snapshot.copyWith(
    parts: [],
    thinkingActive: false,
    lastSeq: 0,
    clearPendingPermission: true,
    clearPendingAsk: true,
    clearStartedAt: true,
  );
}

StreamPhase phaseForStatus(String status) {
  return switch (status) {
    'running' => StreamPhase.running,
    'completed' => StreamPhase.completed,
    'stopped' => StreamPhase.stopped,
    'failed' => StreamPhase.failed,
    _ => StreamPhase.idle,
  };
}

int? _parseSeq(String? id) {
  if (id == null || id.isEmpty) return null;
  return int.tryParse(id);
}
