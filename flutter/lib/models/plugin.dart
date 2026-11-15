/// An installed or project plugin, as reported by `GET /api/plugins`.
/// A plugin bundles skills, slash commands, MCP servers, and event hooks.
class PluginInfo {
  final String name;
  final String version;
  final String description;
  final String author;
  final bool enabled;

  /// `user` for `~/.config/devinorium/plugins`, `project` for a working
  /// directory's `.devinorium/plugins`.
  final String source;

  /// `dir`, `git`, or `link`; how the plugin landed in the plugins root.
  final String install;
  final String path;

  /// Whether the server can toggle, update, or uninstall it (user scope).
  final bool manageable;
  final List<String> skills;
  final List<String> commands;
  final List<String> mcpServers;
  final List<String> hooks;

  const PluginInfo({
    required this.name,
    this.version = '',
    this.description = '',
    this.author = '',
    this.enabled = true,
    this.source = 'user',
    this.install = 'dir',
    this.path = '',
    this.manageable = false,
    this.skills = const [],
    this.commands = const [],
    this.mcpServers = const [],
    this.hooks = const [],
  });

  factory PluginInfo.fromJson(Map<String, dynamic> j) {
    List<String> names(dynamic v) => [
      for (final e in (v as List? ?? const []))
        if (e is String) e,
    ];
    return PluginInfo(
      name: j['name'] as String? ?? '',
      version: j['version'] as String? ?? '',
      description: j['description'] as String? ?? '',
      author: j['author'] as String? ?? '',
      enabled: j['enabled'] as bool? ?? true,
      source: j['source'] as String? ?? 'user',
      install: j['install'] as String? ?? 'dir',
      path: j['path'] as String? ?? '',
      manageable: j['manageable'] as bool? ?? false,
      skills: names(j['skills']),
      commands: names(j['commands']),
      mcpServers: names(j['mcpServers']),
      hooks: names(j['hooks']),
    );
  }
}
