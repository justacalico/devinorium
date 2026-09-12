import 'dart:convert';

/// A single entry in the server audit log, from `GET /api/audit`.
class AuditEntry {
  final int id;
  final int? userId;

  /// Username of the acting user, or null for system events and users that
  /// were deleted after the entry was written.
  final String? username;
  final String action;

  /// Structured detail payload (the server stores it as JSON text and emits
  /// it parsed).
  final Map<String, dynamic> detail;
  final String? ipHash;
  final String createdAt;

  const AuditEntry({
    required this.id,
    this.userId,
    this.username,
    required this.action,
    this.detail = const {},
    this.ipHash,
    this.createdAt = '',
  });

  factory AuditEntry.fromJson(Map<String, dynamic> j) => AuditEntry(
    id: (j['id'] as num).toInt(),
    userId: (j['user_id'] as num?)?.toInt(),
    username: j['username'] as String?,
    action: j['action'] as String? ?? '',
    detail: switch (j['detail']) {
      Map<String, dynamic> m => m,
      String s => _decodeDetail(s),
      _ => const {},
    },
    ipHash: j['ip_hash'] as String?,
    createdAt: j['created_at'] as String? ?? '',
  );

  static Map<String, dynamic> _decodeDetail(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {}
    return const {};
  }
}
