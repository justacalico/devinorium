import '../models/models.dart';

/// Status of a turn/stream for a thread.
enum StreamPhase { idle, sending, running, completed, stopped, failed }

/// Pure snapshot of an in-progress or recently-finished stream.
///
/// t3code keeps per-turn streaming state separate from the persisted message
/// list and reduces it from events. This class is the same idea: a compact,
/// immutable value that the UI can read and the reducer can transform.
///
/// The [digest] is a fast, order-sensitive hash of [parts] so the UI can tell
/// when the stream has changed without walking the whole list on every frame.
class StreamingSnapshot {
  final StreamPhase phase;
  final List<MessagePart> parts;
  final bool thinkingActive;
  final int lastSeq;
  final PermissionRequest? pendingPermission;
  final AskRequest? pendingAsk;
  final Plan? plan;
  final String? error;
  final String? startedAt;
  final int digest;

  const StreamingSnapshot({
    this.phase = StreamPhase.idle,
    this.parts = const [],
    this.thinkingActive = false,
    this.lastSeq = 0,
    this.pendingPermission,
    this.pendingAsk,
    this.plan,
    this.error,
    this.startedAt,
    this.digest = 0,
  });

  static const empty = StreamingSnapshot();

  static int digestForParts(List<MessagePart> parts) => listDigest(parts);

  bool get isActive =>
      phase == StreamPhase.sending || phase == StreamPhase.running;
  bool get isDone =>
      phase == StreamPhase.completed || phase == StreamPhase.stopped;
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
    Plan? plan,
    bool clearPlan = false,
    String? error,
    bool clearError = false,
    String? startedAt,
    bool clearStartedAt = false,
    int? digest,
  }) {
    final nextParts = parts ?? this.parts;
    final nextDigest = digest ??
        (parts != null
            ? (identical(parts, this.parts)
                ? this.digest
                : StreamingSnapshot.digestForParts(nextParts))
            : this.digest);
    return StreamingSnapshot(
      phase: phase ?? this.phase,
      parts: nextParts,
      thinkingActive: thinkingActive ?? this.thinkingActive,
      lastSeq: lastSeq ?? this.lastSeq,
      pendingPermission: clearPendingPermission
          ? null
          : (pendingPermission ?? this.pendingPermission),
      pendingAsk: clearPendingAsk ? null : (pendingAsk ?? this.pendingAsk),
      plan: clearPlan ? null : (plan ?? this.plan),
      error: clearError ? null : (error ?? this.error),
      startedAt: clearStartedAt ? null : (startedAt ?? this.startedAt),
      digest: nextDigest,
    );
  }
}
