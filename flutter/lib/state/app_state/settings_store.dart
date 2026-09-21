part of 'package:devinorium_frontend/state/app_state.dart';

mixin SettingsStore on AppStateBase {
  @override
  Locale _locale = const Locale('en');
  @override
  String _language = 'system';
  @override
  int _settingsTopicIndex = 0;
  static final _supportedLanguageCodes =
      AppLocalizations.supportedLocales.map((l) => l.languageCode).toSet();
  @override
  NotificationService _notifications = NotificationService();
  @override
  Locale get locale => _locale;
  @override
  String get language =>
      _language == 'system' ? 'system' : _localeFromTag(_language).languageCode;
  @override
  int get settingsTopicIndex => _settingsTopicIndex;
  @override
  bool get notificationsEnabled => _notifications.notificationsEnabled;
  @override
  void setSettingsTopicIndex(int index) {
    _settingsTopicIndex = index;
    notifyListeners();
  }
  @override
  Future<void> setLanguage(String language) async {
    _language = language;
    _locale = _resolveLanguage(language);
    setAppL10n(_locale);
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('devinorium_language', language);
    } catch (_) {}
  }
  @override
  Future<void> _loadLanguage() async {
    var value = 'system';
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString('devinorium_language');
      if (stored != null && stored.isNotEmpty) value = stored;
    } catch (_) {}
    _language = value;
    _locale = _resolveLanguage(value);
    setAppL10n(_locale);
    notifyListeners();
  }

  /// Re-resolve the locale when the OS language list changes. Only the
  /// "system" choice follows the platform; a picked language stays put.
  @override
  void handleLocalesChanged(List<Locale>? locales) {
    if (_language != 'system') return;
    final resolved = _systemLocale(locales);
    if (resolved == _locale) return;
    _locale = resolved;
    setAppL10n(_locale);
    notifyListeners();
  }

  Locale _resolveLanguage(String language) {
    return language == 'system'
        ? _systemLocale(null)
        : _localeFromTag(language);
  }

  Locale _systemLocale(List<Locale>? locales) {
    // Walk the OS preference list like localeListResolutionCallback does:
    // the first supported entry wins, otherwise English.
    for (final locale in locales ?? PlatformDispatcher.instance.locales) {
      final code = locale.languageCode;
      if (_supportedLanguageCodes.contains(code)) return Locale(code);
    }
    return const Locale('en');
  }

  Locale _localeFromTag(String tag) {
    final code = tag.contains('-') ? tag.substring(0, tag.indexOf('-')) : tag;
    return _supportedLanguageCodes.contains(code)
        ? Locale(code)
        : const Locale('en');
  }

  @override
  bool _pushEnabled = false;
  @override
  bool get pushEnabled => _pushEnabled;
  @override
  bool get pushSupported => _notifications.pushSupported;
  @override
  String get pushStatus => _notifications.pushStatus;
  @override
  Future<String> notificationPermissionState() =>
      _notifications.permissionState();
  @override
  Future<int> sendTestPushNotification() => api.sendTestPush();

  /// The locale tag subscriptions are stored with; pushes render in it
  /// server-side. "system" resolves to whatever the app currently shows.
  String get _pushLang => _locale.languageCode;

  @override
  Future<void> setNotificationsEnabled(bool enabled) async {
    await _notifications.setNotificationsEnabled(enabled);
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('devinorium_notifications', enabled);
    } catch (_) {}
  }

  @override
  Future<void> setPushEnabled(bool enabled) async {
    _pushEnabled = enabled;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('devinorium_push', enabled);
    } catch (_) {}
    // Toggling from settings is a user gesture, so the browser permission
    // prompt is allowed here — unlike the silent re-sync on login.
    if (_user != null) {
      await _notifications.syncPush(
        api: api,
        lang: _pushLang,
        enabled: enabled,
        allowPrompt: true,
      );
      notifyListeners();
    }
  }

  /// Re-register the browser's push subscription with the active server.
  /// Called after login and server switches: the same browser endpoint gets
  /// bound to the current user, and a subscription the browser rotated
  /// silently is picked back up. Never prompts for permission — a user who
  /// enabled push before already has an active subscription.
  @override
  Future<void> _syncPushSubscription() async {
    if (!_pushEnabled || _user == null) return;
    await _notifications.syncPush(api: api, lang: _pushLang, enabled: true);
    if (!_isDisposed) notifyListeners();
  }

  /// Drop the subscription while the session is still authenticated. The
  /// preference is kept so the next login re-subscribes.
  @override
  Future<void> _teardownPushSubscription() async {
    if (!_pushEnabled) return;
    try {
      await _notifications.syncPush(api: api, lang: _pushLang, enabled: false);
    } catch (_) {}
  }

  @override
  Future<void> _loadNotificationPrefs() async {
    var enabled = false;
    var push = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      enabled = prefs.getBool('devinorium_notifications') ?? false;
      push = prefs.getBool('devinorium_push') ?? false;
    } catch (_) {}
    _pushEnabled = push;
    _notifications.initialize();
    _notifications.onOpenThread = (id) => unawaited(openThread(id));
    await _notifications.setNotificationsEnabled(enabled);
    notifyListeners();
  }
}
