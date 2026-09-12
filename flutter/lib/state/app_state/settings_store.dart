part of 'package:devinorium_frontend/state/app_state.dart';

const _defaultEnvModeKey = 'devinorium_default_env_mode';
const _knownEnvModes = {'local', 'worktree'};

mixin SettingsStore on AppStateBase {
  @override
  Locale _locale = const Locale('en');
  @override
  String _defaultEnvMode = 'local';
  @override
  int _settingsTopicIndex = 0;
  static final _supportedLanguageCodes =
      AppLocalizations.supportedLocales.map((l) => l.languageCode).toSet();
  @override
  final _notifications = NotificationService();
  @override
  Locale get locale => _locale;
  @override
  int get settingsTopicIndex => _settingsTopicIndex;
  @override
  bool get notificationsEnabled => _notifications.notificationsEnabled;
  @override
  String get defaultEnvMode => _defaultEnvMode;
  @override
  void setSettingsTopicIndex(int index) {
    _settingsTopicIndex = index;
    notifyListeners();
  }
  @override
  Future<void> setLanguage(String language) async {
    _locale = _localeFromTag(language);
    setAppL10n(_locale);
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('devinorium_language', language);
    } catch (_) {}
  }
  @override
  Future<void> _loadLanguage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final value = prefs.getString('devinorium_language') ?? 'en';
      _locale = _localeFromTag(value);
    } catch (_) {
      _locale = const Locale('en');
    }
    setAppL10n(_locale);
    notifyListeners();
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
  Future<void> setDefaultEnvMode(String mode) async {
    if (!_knownEnvModes.contains(mode)) return;
    _defaultEnvMode = mode;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_defaultEnvModeKey, mode);
    } catch (_) {}
  }
  @override
  Future<void> _loadDefaultEnvMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final value = prefs.getString(_defaultEnvModeKey);
      if (value != null && _knownEnvModes.contains(value)) {
        _defaultEnvMode = value;
      }
    } catch (_) {}
    notifyListeners();
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
