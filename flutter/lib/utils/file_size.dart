import '../l10n/l10n.dart';

/// Formats a byte count for display in file listings and viewers.
String formatFileSize(int bytes, AppLocalizations l) {
  if (bytes < 1024) return l.sizeBytes('$bytes');
  if (bytes < 1048576) {
    return l.sizeKilobytes((bytes / 1024).toStringAsFixed(1));
  }
  if (bytes < 1073741824) {
    return l.sizeMegabytes((bytes / 1048576).toStringAsFixed(1));
  }
  return l.sizeGigabytes((bytes / 1073741824).toStringAsFixed(1));
}
