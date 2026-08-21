import 'dart:io';

import '../l10n/global_l10n.dart';

class NotificationService {
  bool _notificationsEnabled = false;
  bool _soundEnabled = false;

  bool get notificationsEnabled => _notificationsEnabled;
  bool get soundEnabled => _soundEnabled;

  void setNotificationsEnabled(bool enabled) {
    _notificationsEnabled = enabled;
  }

  void setSoundEnabled(bool enabled) {
    _soundEnabled = enabled;
  }

  void notifyThreadCompleted({required String title, required bool failed}) {
    if (!_notificationsEnabled) return;
    final l = appL10n;
    final headline = failed ? l.threadFailedTitle : l.threadCompletedTitle;
    final body = failed
        ? l.threadFailedBody(title)
        : l.threadCompletedBody(title);
    _showNotification(headline, body);
    if (_soundEnabled) _playSound();
  }

  void _showNotification(String title, String body) {
    try {
      if (Platform.isLinux) {
        Process.run('notify-send', ['--app-name=Devinorium', title, body]);
      } else if (Platform.isMacOS) {
        final script =
            'display notification "$body" with title "Devinorium" subtitle "$title"';
        Process.run('osascript', ['-e', script]);
      } else if (Platform.isWindows) {
        final psScript =
            'Add-Type -AssemblyName System.Windows.Forms;'
            '\$n = New-Object System.Windows.Forms.NotifyIcon;'
            '\$n.Icon = [System.Drawing.SystemIcons]::Information;'
            '\$n.Visible = \$true;'
            "\$n.ShowBalloonTip(5000, 'Devinorium', '$body',"
            ' [System.Windows.Forms.ToolTipIcon]::Info);'
            'Start-Sleep -Seconds 6;'
            '\$n.Dispose()';
        Process.run('powershell', ['-NoProfile', '-Command', psScript]);
      }
    } catch (_) {}
  }

  void _playSound() {
    try {
      if (Platform.isLinux) {
        Process.run('paplay', [
          '/usr/share/sounds/freedesktop/stereo/complete.oga',
        ]);
      } else if (Platform.isMacOS) {
        Process.run('afplay', ['/System/Library/Sounds/Glass.aiff']);
      } else if (Platform.isWindows) {
        Process.run('powershell', [
          '-NoProfile',
          '-Command',
          '[System.Media.SystemSounds]::Asterisk.Play()',
        ]);
      }
    } catch (_) {}
  }
}
