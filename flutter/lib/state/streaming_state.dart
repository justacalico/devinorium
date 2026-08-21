import '../models/models.dart';

/// Status of a turn/stream for a thread.
enum StreamPhase { idle, sending, running, completed, stopped, failed }

/// Pure snapshot of an in-progress or recently-finished stream.
///
/// t3code keeps per-turn streaming state separate from the persisted message
/// list and reduces it from events. This class is the same idea: a compact,
/// immutable value that the UI can read and the reducer can transform.
class StreamingSnapshot {
  final StreamPhase phase;
  final List<MessagePart> parts;
  final bool thinkingActive;
  final int lastSeq;
  final PermissionRequest? pendingPermission;
  final AskRequest? pendingAsk;
  final String? error;
  final String? startedAt;

  const StreamingSnapshot({
    this.phase = StreamPhase.idle,
    this.parts = const [],
    this.thinkingActive = false,
    this.lastSeq = 0,
    this.pendingPermission,
    this.pendingAsk,
    this.error,
    this.startedAt,
  });

  static const empty = StreamingSnapshot();

  bool get isActive => phase == StreamPhase.sending || phase == StreamPhase.running;
  bool get isDone => phase == StreamPhase.completed || phase == StreamPhase.stopped;
  bool get hasFailed => phase == StreamPhase.failed;

  StreamingSnapshot copyWith({
    StreamPhase? phase,
    List<MessagePart>? parts,
    bool? thinkingActive,
    int? lastSeq,
    PermissionRequest? pendingPermission,
    bool clearPendingPermission = false,
    AskRequest? pendingAsk,
    bool clearPendingAsk = false,
    String? error,
    bool clearError = false,
    String? startedAt,
    bool clearStartedAt = false,
  }) {
    return StreamingSnapshot(
      phase: phase ?? this.phase,
      parts: parts ?? this.parts,
      thinkingActive: thinkingActive ?? this.thinkingActive,
      lastSeq: lastSeq ?? this.lastSeq,
      pendingPermission: clearPendingPermission
          ? null
          : (pendingPermission ?? this.pendingPermission),
      pendingAsk: clearPendingAsk ? null : (pendingAsk ?? this.pendingAsk),
      error: clearError ? null : (error ?? this.error),
      startedAt: clearStartedAt ? null : (startedAt ?? this.startedAt),
    );
  }
}
