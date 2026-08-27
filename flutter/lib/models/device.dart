class Device {
  final String deviceId;
  final String tokenPrefix;
  final String? name;
  final String createdAt;
  final String lastSeenAt;
  final String expiresAt;
  final bool isCurrent;

  Device({
    required this.deviceId,
    required this.tokenPrefix,
    this.name,
    required this.createdAt,
    required this.lastSeenAt,
    required this.expiresAt,
    required this.isCurrent,
  });

  factory Device.fromJson(Map<String, dynamic> j) => Device(
    deviceId: j['device_id'] as String? ?? '',
    tokenPrefix: j['token_prefix'] as String? ?? '',
    name: j['name'] as String?,
    createdAt: j['created_at'] as String? ?? '',
    lastSeenAt: j['last_seen_at'] as String? ?? '',
    expiresAt: j['expires_at'] as String? ?? '',
    isCurrent: (j['is_current'] as bool?) ?? false,
  );
}
