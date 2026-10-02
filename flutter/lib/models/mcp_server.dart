/// One MCP server entry from the owner's settings list. Field layout
/// mirrors the common `mcpServers` JSON format: `command`/`args`/`env` for
/// stdio servers, `url`/`headers` for remote ones.
class McpServerConfig {
  final String name;
  final bool enabled;
  final String transport;
  final String command;
  final List<String> args;
  final Map<String, String> env;
  final String url;
  final Map<String, String> headers;

  static const transportStdio = 'stdio';
  static const transportHttp = 'http';
  static const transportSse = 'sse';
  static const transports = [transportStdio, transportHttp, transportSse];

  const McpServerConfig({
    required this.name,
    this.enabled = true,
    this.transport = transportStdio,
    this.command = '',
    this.args = const [],
    this.env = const {},
    this.url = '',
    this.headers = const {},
  });

  bool get isRemote => transport == transportHttp || transport == transportSse;

  /// The one-line summary the settings list shows under the name.
  String get endpoint =>
      isRemote ? url : [command, ...args].where((s) => s.isNotEmpty).join(' ');

  factory McpServerConfig.fromJson(Map<String, dynamic> j) {
    Map<String, String> stringMap(dynamic v) => {
      for (final e in (v as Map? ?? const {}).entries)
        if (e.value is String) e.key.toString(): e.value as String,
    };
    return McpServerConfig(
      name: (j['name'] as String? ?? '').trim(),
      enabled: j['enabled'] as bool? ?? true,
      transport: j['transport'] as String? ?? transportStdio,
      command: j['command'] as String? ?? '',
      args: [
        for (final a in (j['args'] as List? ?? const []))
          if (a is String) a,
      ],
      env: stringMap(j['env']),
      url: j['url'] as String? ?? '',
      headers: stringMap(j['headers']),
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'enabled': enabled,
    'transport': transport,
    if (command.isNotEmpty) 'command': command,
    if (args.isNotEmpty) 'args': args,
    if (env.isNotEmpty) 'env': env,
    if (url.isNotEmpty) 'url': url,
    if (headers.isNotEmpty) 'headers': headers,
  };

  McpServerConfig copyWith({
    String? name,
    bool? enabled,
    String? transport,
    String? command,
    List<String>? args,
    Map<String, String>? env,
    String? url,
    Map<String, String>? headers,
  }) => McpServerConfig(
    name: name ?? this.name,
    enabled: enabled ?? this.enabled,
    transport: transport ?? this.transport,
    command: command ?? this.command,
    args: args ?? this.args,
    env: env ?? this.env,
    url: url ?? this.url,
    headers: headers ?? this.headers,
  );
}
