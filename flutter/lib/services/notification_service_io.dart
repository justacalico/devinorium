import 'dart:async';
import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../api/api_service.dart';
import '../l10n/global_l10n.dart';
import '../utils/debug_log.dart';
import 'notification_text.dart';

/// Android/iOS use flutter_local_notifications; desktop keeps the shell-out
/// implementations (notify-send, osascript, PowerShell) that need no plugin.
class NotificationService {
  bool _notificationsEnabled = false;
  bool _pluginReady = false;
  String? _launchThreadId;
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  void Function(String threadId)? onOpenThread;

  bool get _isMobile => Platform.isAndroid || Platform.isIOS;

  bool get notificationsEnabled => _notificationsEnabled;

  /// Web Push is browser-only; native builds keep local notifications.
  bool get pushSupported => false;

  String get pushStatus => 'unsupported';

  /// Set up the plugin and read a possible launch payload. Called once at
  /// bootstrap; desktop platforms skip it entirely.
  void initialize() {
    if (!_isMobile) return;
    unawaited(_ensurePlugin());
  }

  Future<void> _ensurePlugin() async {
    if (_pluginReady) return;
    _pluginReady = true;
    try {
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(),
        ),
        onDidReceiveNotificationResponse: (response) {
          final id = response.payload;
          if (id != null && id.isNotEmpty) onOpenThread?.call(id);
        },
      );
      final launch = await _plugin.getNotificationAppLaunchDetails();
      if (launch?.didNotificationLaunchApp ?? false) {
        _launchThreadId = launch?.notificationResponse?.payload;
      }
    } catch (e) {
      debugLogFailure('notifications.init', e);
    }
  }

  /// A thread id carried by the notification that cold-started the app, if
  /// any. Consumed on first read.
  String? initialThreadId() {
    final id = _launchThreadId;
    _launchThreadId = null;
    return (id != null && id.isNotEmpty) ? id : null;
  }

  Future<String> permissionState() async {
    if (!_isMobile) return 'granted';
    try {
      await _ensurePlugin();
      if (Platform.isAndroid) {
        final android = _plugin
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >();
        final enabled = await android?.areNotificationsEnabled();
        return (enabled ?? false) ? 'granted' : 'denied';
      }
      final ios = _plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >();
      final enabled = await ios?.checkPermissions();
      return (enabled?.isEnabled ?? false) ? 'granted' : 'denied';
    } catch (_) {
      return 'unsupported';
    }
  }

  Future<void> setNotificationsEnabled(
    bool enabled, {
    bool allowPrompt = true,
  }) async {
    _notificationsEnabled = enabled;
    if (!enabled || !allowPrompt || !_isMobile) return;
    try {
      await _ensurePlugin();
      if (Platform.isAndroid) {
        await _plugin
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >()
            ?.requestNotificationsPermission();
      } else {
        await _plugin
            .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin
            >()
            ?.requestPermissions(alert: true, badge: true, sound: true);
      }
    } catch (e) {
      debugLogFailure('notifications.permission', e);
    }
  }

  void notifyRunEvent({
    required String threadId,
    required String title,
    required String kind,
  }) {
    if (!_notificationsEnabled) return;
    final (headline, body) = runEventText(appL10n, kind, title);
    if (_isMobile) {
      unawaited(_showMobile(headline, body, threadId, kind));
    } else {
      _showDesktop(headline, body);
    }
  }

  Future<void> _showMobile(
    String headline,
    String body,
    String threadId,
    String kind,
  ) async {
    try {
      await _ensurePlugin();
      final urgent = kind == 'permission' || kind == 'ask';
      final l = appL10n;
      await _plugin.show(
        id: Object.hash(kind, threadId) & 0x7fffffff,
        title: headline,
        body: body,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            urgent ? 'attention' : 'runs',
            urgent ? l.notificationChannelAlerts : l.notificationChannelRuns,
            importance: urgent ? Importance.max : Importance.defaultImportance,
            priority: urgent ? Priority.high : Priority.defaultPriority,
          ),
          iOS: const DarwinNotificationDetails(
            presentAlert: true,
            presentBanner: true,
            presentSound: true,
          ),
        ),
        payload: threadId,
      );
    } catch (e) {
      debugLogFailure('notifications.show', e);
    }
  }

  void _showDesktop(String title, String body) {
    try {
      if (Platform.isLinux) {
        Process.run('notify-send', [
          '--app-name=Devinorium',
          title,
          body,
        ]).catchError((_) => ProcessResult(-1, 0, '', ''));
      } else if (Platform.isMacOS) {
        // Thread titles are model-generated text; escape before embedding
        // them in the AppleScript string literals.
        final escapedTitle = title
            .replaceAll('\\', '\\\\')
            .replaceAll('"', '\\"');
        final escapedBody = body
            .replaceAll('\\', '\\\\')
            .replaceAll('"', '\\"');
        final script =
            'display notification "$escapedBody" with title "Devinorium" subtitle "$escapedTitle"';
        Process.run('osascript', [
          '-e',
          script,
        ]).catchError((_) => ProcessResult(-1, 0, '', ''));
      } else if (Platform.isWindows) {
        // PowerShell single-quoted strings escape ' by doubling it.
        final escapedBody = body.replaceAll("'", "''");
        final psScript =
            'Add-Type -AssemblyName System.Windows.Forms;'
            '\$n = New-Object System.Windows.Forms.NotifyIcon;'
            '\$n.Icon = [System.Drawing.SystemIcons]::Information;'
            '\$n.Visible = \$true;'
            "\$n.ShowBalloonTip(5000, 'Devinorium', '$escapedBody',"
            ' [System.Windows.Forms.ToolTipIcon]::Info);'
            'Start-Sleep -Seconds 6;'
            '\$n.Dispose()';
        Process.run('powershell', [
          '-NoProfile',
          '-Command',
          psScript,
        ]).catchError((_) => ProcessResult(-1, 0, '', ''));
      }
    } catch (_) {}
  }

  Future<String> syncPush({
    required ApiService api,
    required String lang,
    required bool enabled,
    bool allowPrompt = false,
  }) async => 'unsupported';
}
