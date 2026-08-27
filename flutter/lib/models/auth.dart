class User {
  final int id;
  final String username;
  final String role;
  final bool totpEnabled;
  final bool isOwner;
  final bool disabled;
  final String createdAt;
  final String providerId;
  final String providerCommand;

  User({
    required this.id,
    required this.username,
    required this.role,
    required this.totpEnabled,
    this.isOwner = false,
    this.disabled = false,
    this.createdAt = '',
    required this.providerId,
    required this.providerCommand,
  });

  factory User.fromJson(Map<String, dynamic> j) => User(
    id: (j['id'] as num).toInt(),
    username: j['username'] as String,
    role: j['role'] as String,
    totpEnabled: (j['totp_enabled'] as bool?) ?? false,
    isOwner: (j['is_owner'] as bool?) ?? false,
    disabled: (j['disabled'] as bool?) ?? false,
    createdAt: j['created_at'] as String? ?? '',
    providerId: j['provider_id'] as String? ?? 'devin-cli',
    providerCommand: (j['provider_command'] as String? ?? '').trim().isEmpty
        ? 'devin'
        : j['provider_command'] as String,
  );

  User copyWith({
    String? providerId,
    String? providerCommand,
    bool? isOwner,
    bool? disabled,
    String? createdAt,
  }) => User(
    id: id,
    username: username,
    role: role,
    totpEnabled: totpEnabled,
    isOwner: isOwner ?? this.isOwner,
    disabled: disabled ?? this.disabled,
    createdAt: createdAt ?? this.createdAt,
    providerId: providerId ?? this.providerId,
    providerCommand: providerCommand ?? this.providerCommand,
  );
}

class LoginResponse {
  final bool ok;
  final bool totpRequired;
  final String username;
  final String token;

  LoginResponse({
    required this.ok,
    required this.totpRequired,
    required this.username,
    this.token = '',
  });

  factory LoginResponse.fromJson(Map<String, dynamic> j) => LoginResponse(
    ok: (j['ok'] as bool?) ?? false,
    totpRequired: (j['totp_required'] as bool?) ?? false,
    username: j['username'] as String? ?? '',
    token: j['token'] as String? ?? '',
  );
}
