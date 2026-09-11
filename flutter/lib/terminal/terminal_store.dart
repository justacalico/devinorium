import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/api_service.dart';
import 'terminal_session.dart';

/// One workspace tab. A tab can hold multiple terminal sessions.
class TerminalTab {
  TerminalTab({required this.id});

  final String id;
  final List<TerminalSession> sessions = [];
}

/// Global terminal workspace shared across the agents and editor views.
///
/// Tabs, sessions, open state, and panel height live here instead of inside a
/// widget, so terminals survive app-mode switches, thread changes, and
/// hide/show toggles.
class TerminalStore extends ChangeNotifier {
  TerminalStore({
    required ApiService Function() api,
    String? Function()? activeThreadId,
    TerminalSessionFactory? sessionFactory,
    // ignore: prefer_initializing_formals
  }) : _api = api,
       _activeThreadId = activeThreadId ?? (() => null),
       sessionFactory = sessionFactory ?? createTerminalSession;

  final ApiService Function() _api;
  final String? Function() _activeThreadId;

  /// Injectable so tests can avoid real PTYs and WebSockets.
  TerminalSessionFactory sessionFactory;

  static const double defaultHeight = 280;
  static const double minHeight = 180;

  final List<TerminalTab> _tabs = [];
  int _activeTabIndex = 0;
  int _tabCounter = 0;
  bool _busy = false;
  bool _open = false;
  bool _disposed = false;
  double _height = defaultHeight;

  List<TerminalTab> get tabs => _tabs;
  int get activeTabIndex => _activeTabIndex;
  bool get busy => _busy;
  bool get open => _open;
  double get height => _height;

  void setOpen(bool value) {
    if (_open == value) return;
    _open = value;
    notifyListeners();
  }

  void toggleOpen() => setOpen(!_open);

  void setHeight(double value) {
    final clamped = value < minHeight ? minHeight : value;
    if (_height == clamped) return;
    _height = clamped;
    notifyListeners();
  }

  void addTab() {
    _tabs.add(TerminalTab(id: 'tab-${_tabCounter++}'));
    _activeTabIndex = _tabs.length - 1;
    notifyListeners();
  }

  void setActiveTab(int index) {
    if (index < 0 || index >= _tabs.length || index == _activeTabIndex) return;
    _activeTabIndex = index;
    notifyListeners();
  }

  /// Spawn a session in the active tab, creating a tab if needed.
  ///
  /// Rethrows factory errors so callers can surface them in the UI.
  Future<void> addSession({required bool local}) async {
    if (_busy || _disposed) return;
    if (_tabs.isEmpty) addTab();

    _busy = true;
    notifyListeners();
    try {
      final session = await sessionFactory(
        api: _api(),
        threadId: _activeThreadId(),
        local: local,
      );
      // The store may have been cleared or disposed while the factory was
      // in flight — drop the session instead of writing to an empty tab list.
      if (_disposed || _tabs.isEmpty || _activeTabIndex >= _tabs.length) {
        session.dispose();
        return;
      }
      session.addListener(notifyListeners);
      _tabs[_activeTabIndex].sessions.add(session);
    } finally {
      _busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  void removeSession(TerminalSession session) {
    for (final tab in _tabs) {
      if (!tab.sessions.remove(session)) continue;
      notifyListeners();
      _disposeSession(session);
      return;
    }
  }

  void removeTab(TerminalTab tab) {
    final index = _tabs.indexOf(tab);
    if (index == -1) return;
    _tabs.removeAt(index);
    if (_activeTabIndex >= _tabs.length) {
      _activeTabIndex = _tabs.isEmpty ? 0 : _tabs.length - 1;
    }
    for (final session in tab.sessions) {
      _disposeSession(session);
    }
    tab.sessions.clear();
    notifyListeners();
  }

  /// Kill every session and reset the workspace. Called on logout and server
  /// switches so no shells outlive the connection they belong to.
  void clear() {
    for (final tab in _tabs) {
      for (final session in tab.sessions) {
        _disposeSession(session);
      }
      tab.sessions.clear();
    }
    _tabs.clear();
    _activeTabIndex = 0;
    _tabCounter = 0;
    _busy = false;
    _open = false;
    notifyListeners();
  }

  void _disposeSession(TerminalSession session) {
    session.removeListener(notifyListeners);
    if (!session.isLocal) {
      // Tell the backend to kill the PTY too — otherwise the shell keeps
      // running on the server until the idle TTL expires.
      try {
        unawaited(_api().killTerminalSession(session.id).catchError((_) {}));
      } catch (_) {}
    }
    session.dispose();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final tab in _tabs) {
      for (final session in tab.sessions) {
        _disposeSession(session);
      }
      tab.sessions.clear();
    }
    _tabs.clear();
    super.dispose();
  }
}
