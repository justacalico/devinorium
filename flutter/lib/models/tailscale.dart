/// Tailscale status returned by `GET /api/tailscale`, mirroring the
/// backend's `TailscaleInfo` and t3code's advertised-endpoint model.
class TailscaleEndpoint {
  /// `tailnet-ip`, `magicdns`, or `tailscale-https`.
  final String kind;
  final String label;
  final String url;

  /// False when the URL exists but the server's bind cannot answer it (a
  /// tailnet-IP URL while bound to loopback, for example).
  final bool reachable;

  const TailscaleEndpoint({
    required this.kind,
    required this.label,
    required this.url,
    required this.reachable,
  });

  factory TailscaleEndpoint.fromJson(Map<String, dynamic> json) {
    return TailscaleEndpoint(
      kind: json['kind'] as String? ?? '',
      label: json['label'] as String? ?? '',
      url: json['url'] as String? ?? '',
      reachable: json['reachable'] as bool? ?? false,
    );
  }
}

class TailscaleInfo {
  /// True on the bundled desktop server, where the feature is disabled.
  final bool localMode;

  /// The `tailscale` binary resolved and ran on the server.
  final bool installed;

  /// `BackendState` from `tailscale status` (`Running`, `NeedsLogin`, ...).
  final String? backendState;

  /// MagicDNS name like `host.tail-abc.ts.net`, when the tailnet provides one.
  final String? magicDnsName;

  /// This node's tailnet IPv4 addresses.
  final List<String> tailnetIpv4;

  /// Whether a `tailscale serve` mapping points at this server.
  final bool serveEnabled;

  /// The persisted owner preference; the mapping is re-applied on startup.
  final bool serveDesired;

  /// Tailnet-side HTTPS port the serve mapping listens on.
  final int servePort;

  /// `https://<magicdns>/` URL while serve is enabled.
  final String? httpsUrl;

  /// Probe result for [httpsUrl]; null when no probe ran.
  final bool? httpsReachable;

  /// Every address the server advertises, reachable or not.
  final List<TailscaleEndpoint> endpoints;

  const TailscaleInfo({
    required this.localMode,
    required this.installed,
    this.backendState,
    this.magicDnsName,
    this.tailnetIpv4 = const [],
    this.serveEnabled = false,
    this.serveDesired = false,
    this.servePort = 443,
    this.httpsUrl,
    this.httpsReachable,
    this.endpoints = const [],
  });

  factory TailscaleInfo.fromJson(Map<String, dynamic> json) {
    return TailscaleInfo(
      localMode: json['local_mode'] as bool? ?? false,
      installed: json['installed'] as bool? ?? false,
      backendState: json['backend_state'] as String?,
      magicDnsName: json['magic_dns_name'] as String?,
      tailnetIpv4: (json['tailnet_ipv4'] as List<dynamic>? ?? [])
          .whereType<String>()
          .toList(),
      serveEnabled: json['serve_enabled'] as bool? ?? false,
      serveDesired: json['serve_desired'] as bool? ?? false,
      servePort: json['serve_port'] as int? ?? 443,
      httpsUrl: json['https_url'] as String?,
      httpsReachable: json['https_reachable'] as bool?,
      endpoints: (json['endpoints'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .map(TailscaleEndpoint.fromJson)
          .toList(),
    );
  }
}
