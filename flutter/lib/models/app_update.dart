/// The result of checking whether a newer app release exists on GitLab.
class AppUpdate {
  final String currentVersion;
  final String latestVersion;
  final bool updateAvailable;
  final String releaseUrl;

  const AppUpdate({
    this.currentVersion = '',
    this.latestVersion = '',
    this.updateAvailable = false,
    this.releaseUrl = '',
  });

  AppUpdate copyWith({
    String? currentVersion,
    String? latestVersion,
    bool? updateAvailable,
    String? releaseUrl,
  }) => AppUpdate(
    currentVersion: currentVersion ?? this.currentVersion,
    latestVersion: latestVersion ?? this.latestVersion,
    updateAvailable: updateAvailable ?? this.updateAvailable,
    releaseUrl: releaseUrl ?? this.releaseUrl,
  );

  @override
  bool operator ==(Object other) =>
      other is AppUpdate &&
      other.currentVersion == currentVersion &&
      other.latestVersion == latestVersion &&
      other.updateAvailable == updateAvailable &&
      other.releaseUrl == releaseUrl;

  @override
  int get hashCode =>
      Object.hash(currentVersion, latestVersion, updateAvailable, releaseUrl);
}
