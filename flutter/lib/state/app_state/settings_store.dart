part of 'package:devinorium_frontend/state/app_state.dart';

mixin SettingsStore on AppStateBase {
  @override
  ThemeMode _themeMode = ThemeMode.system;
  @override
  Locale _locale = const Locale('en');
  @override
  int _settingsTopicIndex = 0;
  @override
  final _notifications = NotificationService();
  @override
  ThemeMode get themeMode => _themeMode;
  @override
  Locale get locale => _locale;
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
  Future<void> setThemeMode(ThemeMode mode) async {
    _themeMode = mode;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('devinorium_theme_mode', _themeModeToString(mode));
    } catch (_) {}
  }
  static String _themeModeToString(ThemeMode mode) {
    return switch (mode) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      _ => 'system',
    };
  }
  @override
  Future<void> _loadThemeMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final value = prefs.getString('devinorium_theme_mode') ?? 'system';
      _themeMode = _parseThemeMode(value);
    } catch (_) {
      _themeMode = ThemeMode.system;
    }
    notifyListeners();
  }
  static ThemeMode _parseThemeMode(String value) {
    switch (value) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }
  @override
  Future<void> setLanguage(String language) async {
    _locale = Locale(language);
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
      _locale = Locale(value);
    } catch (_) {
      _locale = const Locale('en');
    }
    setAppL10n(_locale);
    notifyListeners();
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
