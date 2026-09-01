import 'dart:convert';
import 'dart:math';

/// A saved Devinorium backend connection.
///
/// Each profile has a stable [id] so the same URL can be saved more than once
/// under different labels. The id is used to key per-server state and API
/// clients in the frontend, mirroring t3code's `environmentId` concept.
class ServerProfile {
  final String id;
  final String label;
  final String baseUrl;
  final String token;
  final String username;
  final DateTime createdAt;
  final bool isPrimary;

  const ServerProfile({
    required this.id,
    required this.label,
    required this.baseUrl,
    required this.token,
    required this.username,
    required this.createdAt,
    this.isPrimary = false,
  });

  ServerProfile copyWith({
    String? id,
    String? label,
    String? baseUrl,
    String? token,
    String? username,
    DateTime? createdAt,
    bool? isPrimary,
  }) {
    return ServerProfile(
      id: id ?? this.id,
      label: label ?? this.label,
      baseUrl: baseUrl ?? this.baseUrl,
      token: token ?? this.token,
      username: username ?? this.username,
      createdAt: createdAt ?? this.createdAt,
      isPrimary: isPrimary ?? this.isPrimary,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'base_url': baseUrl,
        'token': token,
        'username': username,
        'created_at': createdAt.toIso8601String(),
        'is_primary': isPrimary,
      };

  factory ServerProfile.fromJson(Map<String, dynamic> json) {
    return ServerProfile(
      id: json['id'] as String,
      label: json['label'] as String,
      baseUrl: json['base_url'] as String,
      token: json['token'] as String,
      username: json['username'] as String,
      createdAt: DateTime.parse(json['created_at'] as String),
      isPrimary: json['is_primary'] as bool? ?? false,
    );
  }

  String toJsonString() => jsonEncode(toJson());

  factory ServerProfile.fromJsonString(String s) =>
      ServerProfile.fromJson(jsonDecode(s) as Map<String, dynamic>);

  /// Generate a short, URL-safe random id.
  static String generateId() {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    final rand = Random.secure();
    return List.generate(16, (_) => chars[rand.nextInt(chars.length)]).join();
  }
}
