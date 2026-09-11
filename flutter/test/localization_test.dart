import 'package:devinorium_frontend/generated/l10n/app_localizations.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('newly added localization keys resolve', () {
    final l10n = lookupAppLocalizations(const Locale('en'));

    expect(l10n.showMore, 'Show more');
    expect(l10n.loadingMore, 'Loading more…');
    expect(l10n.terminalNoSessions, 'No terminal sessions');
    expect(l10n.terminalTab(2), 'Tab 2');
    expect(l10n.terminalNewTab, 'New tab');
    expect(l10n.terminalCloseTab, 'Close tab');
    expect(l10n.terminalClose, 'Close terminal');
    expect(l10n.terminalLocal, 'Local terminal');
    expect(l10n.terminalRemote, 'Remote terminal');
    expect(l10n.terminalHide, 'Hide terminal');
    expect(l10n.terminalStartFailed('boom'), 'Failed to start terminal: boom');
    expect(l10n.terminalCloseTitle, 'Close terminal?');
    expect(
      l10n.terminalCloseBody,
      'This terminal has running processes or output. Close it anyway?',
    );
    expect(l10n.terminalTabCloseTitle, 'Close tab?');
    expect(
      l10n.terminalTabCloseBody(1),
      'This tab contains 1 active terminal. Close it anyway?',
    );
    expect(
      l10n.terminalTabCloseBody(2),
      'This tab contains 2 active terminals. Close it anyway?',
    );
    expect(l10n.planHide, 'Hide plan');
    expect(l10n.planShow, 'Show plan');
    expect(l10n.planCollapse, 'Collapse plan');
    expect(l10n.planExpand, 'Expand plan');
    expect(l10n.planTitle, 'Plan');
    expect(l10n.planProgress(1, 1, 100), '1 / 1 step · 100%');
    expect(l10n.planProgress(2, 3, 50), '2 / 3 steps · 50%');
    expect(l10n.composerModeCode, 'Code');
    expect(l10n.composerModePlan, 'Plan');
    expect(l10n.composerModeAsk, 'Ask');
    expect(
      l10n.terminalLocalOnlyDesktop,
      'Local terminal is only available on desktop.',
    );
    expect(l10n.terminalConnectionError('boom'), '[connection error: boom]');
    expect(l10n.terminalSessionExited('0'), '[session exited with code 0]');
    expect(l10n.terminalPtyError('boom'), '[pty error: boom]');
    expect(l10n.terminalPtyClosed, '[pty closed]');
    expect(l10n.terminalProcessExited('0'), '[process exited with code 0]');
    expect(
      l10n.terminalShellStartFailed('bash', 'boom'),
      '[failed to start bash: boom]',
    );
    expect(l10n.attachSourcePhotoLibrary, 'Photo Library');
    expect(l10n.attachSourceTakePhotoOrVideo, 'Take Photo or Video');
    expect(l10n.attachSourceTakePhoto, 'Take Photo');
    expect(l10n.attachSourceRecordVideo, 'Record Video');
    expect(l10n.attachSourceBrowse, 'Browse');
    expect(l10n.defaultPermissionLevel, 'Default permission level');
    expect(l10n.defaultPermissionLevelHint, 'Applied to new threads');
  });
}
