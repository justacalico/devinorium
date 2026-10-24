/// A scheduled rate-limit retry reported by the backend while a run is
/// parked between a rate-limited provider call and its retry. The UI renders
/// a countdown from [retryAt].
class RateLimitWait {
  final DateTime retryAt;
  final int attempt;
  final int maxAttempts;
  final String? message;

  const RateLimitWait({
    required this.retryAt,
    required this.attempt,
    required this.maxAttempts,
    this.message,
  });

  Duration get remaining {
    final diff = retryAt.difference(DateTime.now());
    return diff.isNegative ? Duration.zero : diff;
  }

  static RateLimitWait? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final raw = json['retry_at'];
    final retryAt = raw is String ? DateTime.tryParse(raw) : null;
    if (retryAt == null) return null;
    return RateLimitWait(
      retryAt: retryAt,
      attempt: (json['attempt'] as num?)?.toInt() ?? 1,
      maxAttempts: (json['max_attempts'] as num?)?.toInt() ?? 1,
      message: json['message'] as String?,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RateLimitWait &&
          retryAt == other.retryAt &&
          attempt == other.attempt &&
          maxAttempts == other.maxAttempts &&
          message == other.message;

  @override
  int get hashCode => Object.hash(retryAt, attempt, maxAttempts, message);
}
