/// A VNC machine the server can hand to an agent for remote control.
///
/// Machines are configured by the owner under server settings and shared by
/// every account on the instance. The stored password never leaves the
/// backend; `hasPassword` only reports that one is set.
class Machine {
  final int id;
  final String name;
  final String host;
  final int port;
  final bool hasPassword;
  final String createdAt;
  final String updatedAt;

  Machine({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    this.hasPassword = false,
    this.createdAt = '',
    this.updatedAt = '',
  });

  factory Machine.fromJson(Map<String, dynamic> j) => Machine(
    id: (j['id'] as num).toInt(),
    name: j['name'] as String? ?? '',
    host: j['host'] as String? ?? '',
    port: (j['port'] as num?)?.toInt() ?? 5900,
    hasPassword: j['has_password'] as bool? ?? false,
    createdAt: j['created_at'] as String? ?? '',
    updatedAt: j['updated_at'] as String? ?? '',
  );

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! Machine) return false;
    return id == other.id &&
        name == other.name &&
        host == other.host &&
        port == other.port &&
        hasPassword == other.hasPassword &&
        createdAt == other.createdAt &&
        updatedAt == other.updatedAt;
  }

  @override
  int get hashCode =>
      Object.hash(id, name, host, port, hasPassword, createdAt, updatedAt);
}

/// A machine picked in the composer with `@`, sent as a `machine_ids`
/// reference so the run can remote-control it.
class MachineReference {
  final int id;
  final String name;

  const MachineReference({required this.id, required this.name});

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! MachineReference) return false;
    return id == other.id && name == other.name;
  }

  @override
  int get hashCode => Object.hash(id, name);
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
