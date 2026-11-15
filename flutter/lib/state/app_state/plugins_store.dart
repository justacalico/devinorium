part of 'package:devinorium_frontend/state/app_state.dart';

/// Server-installed plugins for the settings page. Owner-only like the
/// MCP list: a plugin can register shell hooks and tool servers, so its
/// management API carries the same trust level.
mixin PluginsStore on AppStateBase {
  @override
  List<PluginInfo> _plugins = [];
  @override
  int _pluginsSeq = 0;

  @override
  List<PluginInfo> get plugins => _plugins;

  /// Pull `GET /api/plugins` for the active server. Non-owners keep an
  /// empty list, and the seq guard keeps a response from a previous server
  /// from landing after a switch.
  @override
  Future<void> loadPlugins() async {
    if (multiServerState.activeApi == null || !isOwner) {
      _pluginsSeq++;
      if (_plugins.isNotEmpty) {
        _plugins = [];
        notifyListeners();
      }
      return;
    }
    final seq = ++_pluginsSeq;
    try {
      final plugins = await api.plugins();
      if (seq != _pluginsSeq) return;
      _plugins = plugins;
      notifyListeners();
    } catch (_) {
      // Keep a previously loaded list on transient failures.
    }
  }

  /// Install from a git URL or local path, then refresh. Returns an error
  /// string on failure.
  @override
  Future<String?> installPlugin(String source) async {
    try {
      await api.installPlugin(source);
      await loadPlugins();
      return null;
    } on ApiException catch (e) {
      return e.message;
    } catch (e) {
      return '$e';
    }
  }

  /// Toggle a plugin; on success the flag is patched locally so the switch
  /// does not wait on a refetch. Returns an error string on failure.
  @override
  Future<String?> setPluginEnabled(String name, bool enabled) async {
    try {
      await api.setPluginEnabled(name, enabled);
      _plugins = [
        for (final p in _plugins)
          p.name == name
              ? PluginInfo(
                  name: p.name,
                  version: p.version,
                  description: p.description,
                  author: p.author,
                  enabled: enabled,
                  source: p.source,
                  install: p.install,
                  path: p.path,
                  manageable: p.manageable,
                  skills: p.skills,
                  commands: p.commands,
                  mcpServers: p.mcpServers,
                  hooks: p.hooks,
                )
              : p,
      ];
      notifyListeners();
      return null;
    } on ApiException catch (e) {
      return e.message;
    } catch (e) {
      return '$e';
    }
  }

  /// `git pull` a git-installed plugin, then refresh. Returns an error
  /// string on failure.
  @override
  Future<String?> updatePlugin(String name) async {
    try {
      await api.updatePlugin(name);
      await loadPlugins();
      return null;
    } on ApiException catch (e) {
      return e.message;
    } catch (e) {
      return '$e';
    }
  }

  /// Uninstall a plugin and drop it from the list. Returns an error
  /// string on failure.
  @override
  Future<String?> deletePlugin(String name) async {
    try {
      await api.deletePlugin(name);
      _plugins = [for (final p in _plugins) if (p.name != name) p];
      notifyListeners();
      return null;
    } on ApiException catch (e) {
      return e.message;
    } catch (e) {
      return '$e';
    }
  }
}
