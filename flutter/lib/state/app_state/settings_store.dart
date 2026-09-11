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
  final _notifications = NotificationService();
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
  Future<void> setNotificationsEnabled(bool enabled) async {
    _notifications.setNotificationsEnabled(enabled);
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('devinorium_notifications', enabled);
    } catch (_) {}
  }
  @override
  Future<void> _loadNotificationPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _notifications.setNotificationsEnabled(
        prefs.getBool('devinorium_notifications') ?? false,
      );
    } catch (_) {}
    notifyListeners();
  }
}
