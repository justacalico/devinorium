import '../generated/l10n/app_localizations.dart';

/// Maps a run lifecycle kind ('completed', 'failed', 'stopped',
/// 'permission', 'ask') to a localized (title, body) pair for `title`'s
/// thread. Unknown kinds fall back to the completed text.
(String, String) runEventText(AppLocalizations l, String kind, String title) {
  return switch (kind) {
    'failed' => (l.threadFailedTitle, l.threadFailedBody(title)),
    'stopped' => (l.threadStoppedTitle, l.threadStoppedBody(title)),
    'permission' => (
      l.threadNeedsPermissionTitle,
      l.threadNeedsPermissionBody(title),
    ),
    'ask' => (l.threadAskTitle, l.threadAskBody(title)),
    _ => (l.threadCompletedTitle, l.threadCompletedBody(title)),
  };
}
