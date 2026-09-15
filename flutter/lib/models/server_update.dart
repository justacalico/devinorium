/// The server's self-update status, from `GET /api/server/update/check`.
class ServerUpdateCheck {
  final String currentVersion;
  final String? latestVersion;
  final String? latestTag;
  final String? releaseUrl;
  final String? assetName;
  final bool updateAvailable;

  /// Whether this instance can self-update. When false, [reason] is one of
  /// `local_mode`, `dev_mode`, or `unsupported_platform`.
  final bool updatable;
  final String? reason;

  const ServerUpdateCheck({
    this.currentVersion = '',
    this.latestVersion,
    this.latestTag,
    this.releaseUrl,
    this.assetName,
    this.updateAvailable = false,
    this.updatable = false,
    this.reason,
  });

  factory ServerUpdateCheck.fromJson(Map<String, dynamic> j) {
    return ServerUpdateCheck(
      currentVersion: j['current_version'] as String? ?? '',
      latestVersion: j['latest_version'] as String?,
      latestTag: j['latest_tag'] as String?,
      releaseUrl: j['release_url'] as String?,
      assetName: j['asset_name'] as String?,
      updateAvailable: j['update_available'] as bool? ?? false,
      updatable: j['updatable'] as bool? ?? false,
      reason: j['reason'] as String?,
    );
  }
}
