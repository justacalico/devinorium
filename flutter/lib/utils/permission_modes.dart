import '../generated/l10n/app_localizations.dart';

/// Permission modes offered by the pickers, in display order. Keep in sync
/// with the backend's `is_valid_permission_mode`.
const permissionModeIds = ['normal', 'accept-edits', 'smart', 'bypass'];

List<(String, String)> permissionModeLabels(AppLocalizations l) => [
  ('normal', l.permissionModeNormal),
  ('accept-edits', l.permissionModeAcceptEdits),
  ('smart', l.permissionModeSmart),
  ('bypass', l.permissionModeBypass),
];
