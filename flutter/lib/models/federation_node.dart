/// A satellite backend registered with this server (the hub).
///
/// Selecting a node routes every API call through the hub's
/// `/api/federation/nodes/<id>/proxy` prefix, so the satellite's own
/// threads, projects, and providers answer instead of the hub's.
class FederationNode {
  final String id;
  final String name;
  final String baseUrl;
  final String version;
  final bool online;
  final String lastSeenAt;

  FederationNode({
    required this.id,
    required this.name,
    this.baseUrl = '',
    this.version = '',
    this.online = false,
    this.lastSeenAt = '',
  });

  factory FederationNode.fromJson(Map<String, dynamic> j) => FederationNode(
    id: j['id'] as String? ?? '',
    name: j['name'] as String? ?? '',
    baseUrl: j['base_url'] as String? ?? '',
    version: j['version'] as String? ?? '',
    online: j['online'] as bool? ?? false,
    lastSeenAt: j['last_seen_at'] as String? ?? '',
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is FederationNode &&
          id == other.id &&
          name == other.name &&
          baseUrl == other.baseUrl &&
          version == other.version &&
          online == other.online &&
          lastSeenAt == other.lastSeenAt);

  @override
  int get hashCode =>
      Object.hash(id, name, baseUrl, version, online, lastSeenAt);
}

/// Response of `GET /api/federation/nodes`: the hub itself plus the
/// satellites currently registered with it.
class FederationNodesResponse {
  final String selfName;
  final String selfVersion;
  final List<FederationNode> nodes;

  FederationNodesResponse({
    this.selfName = '',
    this.selfVersion = '',
    this.nodes = const [],
  });

  factory FederationNodesResponse.fromJson(Map<String, dynamic> j) {
    final self = j['self'];
    return FederationNodesResponse(
      selfName: self is Map<String, dynamic>
          ? (self['name'] as String? ?? '')
          : '',
      selfVersion: self is Map<String, dynamic>
          ? (self['version'] as String? ?? '')
          : '',
      nodes: [
        for (final n in j['nodes'] as List? ?? const [])
          FederationNode.fromJson(n as Map<String, dynamic>),
      ],
    );
  }
}
