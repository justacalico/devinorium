/// `.mcpb` bundle metadata returned by the inspect endpoint: the manifest's
/// identity plus the `user_config` schema the install dialog renders.
class McpbUserConfig {
  final String key;
  final String type;
  final String title;
  final String description;
  final bool required;
  final bool sensitive;
  final bool multiple;
  final dynamic defaultValue;
  final double? min;
  final double? max;

  const McpbUserConfig({
    required this.key,
    this.type = 'string',
    this.title = '',
    this.description = '',
    this.required = false,
    this.sensitive = false,
    this.multiple = false,
    this.defaultValue,
    this.min,
    this.max,
  });

  static const typeString = 'string';
  static const typeNumber = 'number';
  static const typeBoolean = 'boolean';
  static const typeDirectory = 'directory';
  static const typeFile = 'file';

  bool get isBoolean => type == typeBoolean;
  bool get isNumber => type == typeNumber;

  factory McpbUserConfig.fromJson(Map<String, dynamic> j) {
    double? num_(dynamic v) => v is num ? v.toDouble() : double.tryParse('$v');
    return McpbUserConfig(
      key: j['key'] as String? ?? '',
      type: j['type'] as String? ?? typeString,
      title: j['title'] as String? ?? '',
      description: j['description'] as String? ?? '',
      required: j['required'] as bool? ?? false,
      sensitive: j['sensitive'] as bool? ?? false,
      multiple: j['multiple'] as bool? ?? false,
      defaultValue: j['default'],
      min: num_(j['min']),
      max: num_(j['max']),
    );
  }
}

class McpbInfo {
  final String name;
  final String displayName;
  final String version;
  final String description;
  final String author;
  final String license;
  final String homepage;
  final String serverType;
  final List<McpbUserConfig> userConfig;
  final List<String> warnings;

  const McpbInfo({
    required this.name,
    this.displayName = '',
    this.version = '',
    this.description = '',
    this.author = '',
    this.license = '',
    this.homepage = '',
    this.serverType = '',
    this.userConfig = const [],
    this.warnings = const [],
  });

  factory McpbInfo.fromJson(Map<String, dynamic> j) => McpbInfo(
    name: j['name'] as String? ?? '',
    displayName: j['displayName'] as String? ?? '',
    version: j['version'] as String? ?? '',
    description: j['description'] as String? ?? '',
    author: j['author'] as String? ?? '',
    license: j['license'] as String? ?? '',
    homepage: j['homepage'] as String? ?? '',
    serverType: j['serverType'] as String? ?? '',
    userConfig: [
      for (final f in (j['userConfig'] as List? ?? const []))
        McpbUserConfig.fromJson(f as Map<String, dynamic>),
    ],
    warnings: [for (final w in (j['warnings'] as List? ?? const [])) '$w'],
  );
}
