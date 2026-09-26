/// A machine the server can hand to an agent for remote control.
///
/// Machines are configured by the owner under server settings and shared by
/// every account on the instance. `kind` is the protocol scope: `vnc`
/// (screen control) or `ssh` (remote shell). Stored secrets never leave
/// the backend; `hasPassword`/`hasSshKey` only report that they are set.
class Machine {
  static const kindVnc = 'vnc';
  static const kindSsh = 'ssh';

  final int id;
  final String name;
  final String kind;
  final String host;
  final int port;
  final String sshUser;
  /// Pinned SSH host-key fingerprint (TOFU); empty until a probe sees one.
  final String sshFingerprint;
  final bool hasPassword;
  final bool hasSshKey;
  final String createdAt;
  final String updatedAt;

  Machine({
    required this.id,
    required this.name,
    this.kind = kindVnc,
    required this.host,
    required this.port,
    this.sshUser = '',
    this.sshFingerprint = '',
    this.hasPassword = false,
    this.hasSshKey = false,
    this.createdAt = '',
    this.updatedAt = '',
  });

  bool get isSsh => kind == kindSsh;

  /// `user@host:port` for ssh machines, `host:port` otherwise.
  String get endpoint =>
      isSsh && sshUser.isNotEmpty ? '$sshUser@$host:$port' : '$host:$port';

  factory Machine.fromJson(Map<String, dynamic> j) {
    final kind = j['kind'] as String? ?? kindVnc;
    return Machine(
      id: (j['id'] as num).toInt(),
      name: j['name'] as String? ?? '',
      kind: kind,
      host: j['host'] as String? ?? '',
      port:
          (j['port'] as num?)?.toInt() ??
          (kind == kindSsh ? 22 : 5900),
      sshUser: j['ssh_user'] as String? ?? '',
      sshFingerprint: j['ssh_fingerprint'] as String? ?? '',
      hasPassword: j['has_password'] as bool? ?? false,
      hasSshKey: j['has_ssh_key'] as bool? ?? false,
      createdAt: j['created_at'] as String? ?? '',
      updatedAt: j['updated_at'] as String? ?? '',
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! Machine) return false;
    return id == other.id &&
        name == other.name &&
        kind == other.kind &&
        host == other.host &&
        port == other.port &&
        sshUser == other.sshUser &&
        sshFingerprint == other.sshFingerprint &&
        hasPassword == other.hasPassword &&
        hasSshKey == other.hasSshKey &&
        createdAt == other.createdAt &&
        updatedAt == other.updatedAt;
  }

  @override
  int get hashCode => Object.hash(
    id,
    name,
    kind,
    host,
    port,
    sshUser,
    sshFingerprint,
    hasPassword,
    hasSshKey,
    createdAt,
    updatedAt,
  );
}

/// A machine picked in the composer with `@`, sent as a `machine_ids`
/// reference so the run can remote-control it.
class MachineReference {
  final int id;
  final String name;
  final String kind;

  const MachineReference({
    required this.id,
    required this.name,
    this.kind = Machine.kindVnc,
  });

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! MachineReference) return false;
    return id == other.id && name == other.name && kind == other.kind;
  }

  @override
  int get hashCode => Object.hash(id, name, kind);
}

/// Outcome of the owner-only `POST /api/machines/:id/test` handshake probe.
class MachineTestResult {
  final bool ok;
  final String? error;
  final int? width;
  final int? height;
  final String? name;

  MachineTestResult({
    required this.ok,
    this.error,
    this.width,
    this.height,
    this.name,
  });

  factory MachineTestResult.fromJson(Map<String, dynamic> j) =>
      MachineTestResult(
        ok: j['ok'] as bool? ?? false,
        error: j['error'] as String?,
        width: (j['width'] as num?)?.toInt(),
        height: (j['height'] as num?)?.toInt(),
        name: j['name'] as String?,
      );
}
