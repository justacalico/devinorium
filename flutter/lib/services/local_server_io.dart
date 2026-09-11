import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../utils/debug_log.dart';
import 'local_server_types.dart';

/// Signature for spawning the server process. Injectable so tests can supply
/// a stand-in process without a real devinorium binary.
typedef ServerProcessStarter = Future<Process> Function(
  String executable,
  List<String> arguments, {
  required Map<String, String> environment,
  required String workingDirectory,
});

/// Runs the devinorium server binary that ships inside desktop builds.
///
/// The server is spawned on a random loopback port with a fresh
/// `DEVINORIUM_LOCAL_TOKEN`, so the bundled backend needs no login while
/// other users on the machine cannot use the API (the token stays in
/// user-private storage; same-user processes could still read it from the
/// child's environment — that is the accepted limit of local mode). The child
/// process exits on its own when the app dies because the server watches
/// stdin (see `spawn_stdin_watchdog` in `src/main.rs`).
class LocalServerManager implements LocalServerController {
  /// Optional binary override for development:
  /// `flutter run --dart-define=DEVINORIUM_SERVER_BINARY=/path/to/devinorium`.
  static const _binaryOverride =
      String.fromEnvironment('DEVINORIUM_SERVER_BINARY');

  static const _healthTimeout = Duration(seconds: 15);
  static const _maxQuickExits = 3;
  static const _quickExitWindow = Duration(seconds: 30);

  LocalServerManager({
    String? executablePath,
    Map<String, String>? environment,
    String? binaryPath,
    this.dataDir,
    bool? supported,
    ServerProcessStarter? spawnProcess,
    Future<bool> Function(Uri url)? healthCheck,
    Future<bool> Function(LocalServerEndpoint endpoint)? verifyEndpoint,
    this.onExit,
  })  : _executablePath = executablePath ?? Platform.resolvedExecutable,
        _environment = environment ?? Platform.environment,
        _binaryPath = _nonEmpty(binaryPath ?? _binaryOverride),
        _supported = supported ?? _defaultSupported,
        _spawn = spawnProcess ?? _defaultSpawn,
        _healthCheck = healthCheck ?? _defaultHealthCheck,
        _verifyEndpoint = verifyEndpoint ?? _defaultVerify;

  /// A manager that never spawns anything. Used by tests that do not exercise
  /// the bundled server.
  factory LocalServerManager.disabled() => LocalServerManager(supported: false);

  static bool get _defaultSupported =>
      Platform.isLinux || Platform.isMacOS || Platform.isWindows;

  static String? _nonEmpty(String? s) =>
      s == null || s.isEmpty ? null : s;

  final String _executablePath;
  final Map<String, String> _environment;
  final String? _binaryPath;
  final bool _supported;
  final ServerProcessStarter _spawn;
  final Future<bool> Function(Uri url) _healthCheck;
  final Future<bool> Function(LocalServerEndpoint endpoint) _verifyEndpoint;

  Process? _process;
  bool _exited = true;
  bool _stopping = false;
  LocalServerEndpoint? _endpoint;
  DateTime? _lastSpawnAt;
  int _quickExits = 0;
  Future<LocalServerEndpoint?>? _starting;

  /// Optional override for the data directory (default: per-user app data).
  final String? dataDir;

  /// Called when the spawned server exits on its own (crash or kill), but not
  /// after a deliberate [stop].
  @override
  void Function(int exitCode)? onExit;

  /// Whether this platform can run a bundled server.
  @override
  bool get isSupported => _supported;

  /// The live endpoint, or `null` when no server is currently running.
  @override
  LocalServerEndpoint? get endpoint => _endpoint;

  /// Ordered search list for the bundled binary: explicit override, then
  /// `server/` next to the app executable, then the executable's own
  /// directory.
  List<String> binaryCandidates() {
    final exeDir = p.dirname(_executablePath);
    final name = binaryFileName(Platform.operatingSystem);
    return [
      ?_binaryPath,
      p.join(exeDir, 'server', name),
      p.join(exeDir, name),
    ];
  }

  static String binaryFileName(String operatingSystem) =>
      operatingSystem == 'windows' ? 'devinorium.exe' : 'devinorium';

  /// The per-user data directory for the bundled server's database. Written
  /// against an explicit `operatingSystem` string so tests can cover every
  /// platform.
  static String dataDirPath(String operatingSystem, Map<String, String> env) {
    final ctx = operatingSystem == 'windows' ? p.windows : p.posix;
    final home = env['HOME'] ?? env['USERPROFILE'];
    switch (operatingSystem) {
      case 'windows':
        final base = env['LOCALAPPDATA'] ?? env['APPDATA'];
        if (base != null && base.isNotEmpty) {
          return ctx.join(base, 'devinorium');
        }
      case 'macos':
        if (home != null && home.isNotEmpty) {
          return ctx.join(
            home,
            'Library',
            'Application Support',
            'devinorium',
          );
        }
      default:
        final xdg = env['XDG_DATA_HOME'];
        if (xdg != null && xdg.isNotEmpty) return ctx.join(xdg, 'devinorium');
        if (home != null && home.isNotEmpty) {
          return ctx.join(home, '.local', 'share', 'devinorium');
        }
    }
    // Last resort on machines without a home dir: keep the path per-user so
    // another account cannot pre-create it and read the published token.
    final user = env['USER'] ?? env['LOGNAME'] ?? env['USERNAME'] ?? 'shared';
    return ctx.join(Directory.systemTemp.path, 'devinorium-$user');
  }

  /// Whether a bundled server binary is actually present next to the app.
  @override
  bool get hasBinary => _supported && _resolveBinary() != null;

  /// Start the bundled server if it is not already running and return its
  /// endpoint. Returns `null` when the platform is unsupported or no bundled
  /// binary exists — callers should fall back to the manual server flow.
  /// Concurrent callers share a single spawn attempt.
  @override
  Future<LocalServerEndpoint?> ensureRunning() {
    if (!_supported) {
      return Future.value(null);
    }
    final running = _process;
    if (_endpoint != null && running != null && !_exited) {
      return Future.value(_endpoint);
    }
    final inFlight = _starting;
    if (inFlight != null) return inFlight;
    final future = _start();
    _starting = future;
    return future.whenComplete(() => _starting = null);
  }

  Future<LocalServerEndpoint?> _start() async {
    // A second app instance cannot spawn its own server (the backend takes a
    // single-instance lock on the database), so adopt the endpoint the first
    // instance published if it still answers. Adoption runs before the
    // quick-exit cap so a crash loop never locks out a healthy shared server.
    final adopted = await _adoptExisting();
    if (adopted != null) return adopted;

    if (_stopping) return null;
    if (_quickExits >= _maxQuickExits) return null;

    final binary = _resolveBinary();
    if (binary == null) {
      debugLogFailure('localServer.resolve', 'no bundled server binary');
      return null;
    }

    final dataDir = Directory(_dataDirPath);
    try {
      await dataDir.create(recursive: true);
      await _makePrivate(dataDir);
    } catch (e) {
      debugLogFailure('localServer.dataDir', e);
      return null;
    }

    final port = await _pickPort();
    final token = generateToken();
    final dbPath = p.join(dataDir.path, 'devinorium.db');
    final env = _serverEnvironment(port: port, token: token, dbPath: dbPath);

    final Process proc;
    try {
      _lastSpawnAt = DateTime.now();
      proc = await _spawn(
        binary,
        const [],
        environment: env,
        workingDirectory: dataDir.path,
      );
    } catch (e) {
      debugLogFailure('localServer.spawn', e);
      return null;
    }
    if (_stopping) {
      // dispose() ran while the process was starting.
      proc.kill();
      return null;
    }
    _attach(proc);

    if (!await _waitForHealth(port)) {
      // _detach untracks the process before we kill it, so the exit handler
      // ignores this deliberate kill (no onExit, no quick-exit penalty).
      _detach();
      proc.kill();
      return null;
    }
    _quickExits = 0;
    _endpoint = LocalServerEndpoint(
      baseUrl: 'http://127.0.0.1:$port',
      token: token,
    );
    unawaited(_writeEndpointFile(_endpoint!));
    return _endpoint;
  }

  /// Stop the bundled server. Safe to call when nothing is running.
  @override
  Future<void> stop() async {
    _stopping = true;
    final proc = _process;
    _process = null;
    _endpoint = null;
    _exited = true;
    try {
      if (proc == null) return;
      proc.kill();
      try {
        await proc.exitCode.timeout(const Duration(seconds: 5));
      } on TimeoutException {
        // Already dead or refusing to die; nothing more to do.
      }
      await _deleteEndpointFile();
    } finally {
      _stopping = false;
    }
  }

  @override
  void dispose() {
    unawaited(stop());
  }

  String? _resolveBinary() {
    for (final candidate in binaryCandidates()) {
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  String get _dataDirPath =>
      dataDir ?? dataDirPath(Platform.operatingSystem, _environment);

  File get _endpointFile => File(p.join(_dataDirPath, 'endpoint.json'));

  /// Reuse the endpoint a still-running instance of the bundled server
  /// published into the shared data directory. Only loopback URLs are
  /// trusted; a file pointing anywhere else is treated as stale.
  Future<LocalServerEndpoint?> _adoptExisting() async {
    final file = _endpointFile;
    if (!file.existsSync()) return null;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return null;
      final baseUrl = decoded['base_url'];
      final token = decoded['token'];
      if (baseUrl is! String || token is! String) return null;
      if (!_isLoopbackUrl(baseUrl)) return null;
      final ep = LocalServerEndpoint(baseUrl: baseUrl, token: token);
      if (await _verifyEndpoint(ep)) {
        _endpoint = ep;
        return ep;
      }
    } catch (_) {
      // A missing, corrupt, or stale endpoint file just means we spawn.
    }
    return null;
  }

  static bool _isLoopbackUrl(String baseUrl) {
    final uri = Uri.tryParse(baseUrl);
    if (uri == null || uri.scheme != 'http') return false;
    final host = uri.host.toLowerCase();
    if (host == 'localhost' || host == '[::1]') return true;
    final octets = host.split('.');
    if (octets.length != 4) return false;
    if (octets.any((o) => int.tryParse(o) == null)) return false;
    return octets[0] == '127';
  }

  Future<void> _writeEndpointFile(LocalServerEndpoint ep) async {
    try {
      final target = _endpointFile;
      final tmp = File('${target.path}.tmp');
      await tmp.writeAsString(
        jsonEncode({'base_url': ep.baseUrl, 'token': ep.token}),
      );
      await _makePrivate(tmp);
      await tmp.rename(target.path);
    } catch (e) {
      debugLogFailure('localServer.endpointFile', e);
    }
  }

  /// Restrict a path to the current user where the platform supports it.
  /// Windows per-user directories are already private by ACL.
  static Future<void> _makePrivate(FileSystemEntity entity) async {
    if (Platform.isWindows) return;
    try {
      await Process.run('chmod', ['700', entity.path]);
    } catch (_) {}
  }

  Future<void> _deleteEndpointFile() async {
    try {
      final file = _endpointFile;
      if (file.existsSync()) await file.delete();
    } catch (_) {}
  }

  /// The stored endpoint is only trusted when its token authenticates as the
  /// local-mode account — not merely when some server answers on that port.
  static Future<bool> _defaultVerify(LocalServerEndpoint ep) async {
    try {
      final resp = await http
          .get(
            Uri.parse('${ep.baseUrl}/api/auth/me'),
            headers: {'authorization': 'Bearer ${ep.token}'},
          )
          .timeout(const Duration(seconds: 2));
      if (resp.statusCode != 200) return false;
      final body = jsonDecode(resp.body);
      return body is Map<String, dynamic> &&
          body['username'] == 'local' &&
          body['is_owner'] == true;
    } catch (_) {
      return false;
    }
  }

  Future<int> _pickPort() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    return port;
  }

  /// Generate a random 64-hex-char token for `DEVINORIUM_LOCAL_TOKEN`.
  @visibleForTesting
  static String generateToken() {
    final rand = Random.secure();
    return List.generate(
      32,
      (_) => rand.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  Map<String, String> _serverEnvironment({
    required int port,
    required String token,
    required String dbPath,
  }) {
    // The app process may inherit user-exported DEVINORIUM_* settings (a
    // bootstrap password, proxy trust, allowed origin) that would silently
    // change the bundled server's security posture — strip them and set only
    // what local mode needs.
    final env = Map<String, String>.of(_environment)
      ..removeWhere((key, _) => key.startsWith('DEVINORIUM_'));
    env['DEVINORIUM_HOST'] = '127.0.0.1';
    env['DEVINORIUM_PORT'] = '$port';
    env['DEVINORIUM_DB_URL'] = _sqliteUrl(dbPath, Platform.operatingSystem);
    env['DEVINORIUM_LOCAL_TOKEN'] = token;
    // An ephemeral session key silences the startup warning; local mode
    // never issues session cookies anyway.
    env['DEVINORIUM_SESSION_KEY'] = generateToken();
    return env;
  }

  /// sqlx treats the text after `sqlite:` as a literal path, so normalize
  /// Windows separators instead of percent-encoding.
  static String _sqliteUrl(String dbPath, String operatingSystem) {
    final normalized =
        operatingSystem == 'windows' ? dbPath.replaceAll('\\', '/') : dbPath;
    return 'sqlite:$normalized?mode=rwc';
  }

  void _attach(Process proc) {
    _process = proc;
    _exited = false;
    final spawnedAt = _lastSpawnAt;
    proc.exitCode.then((code) {
      // A newer spawn may already have replaced this process; only touch
      // state (and fire onExit) when the dead process is still the tracked
      // one.
      if (!identical(_process, proc)) return;
      _exited = true;
      _process = null;
      _endpoint = null;
      final quick = spawnedAt != null &&
          DateTime.now().difference(spawnedAt) < _quickExitWindow;
      _quickExits = quick ? _quickExits + 1 : 0;
      if (!_stopping) onExit?.call(code);
    });
    // Drain both pipes so the child never blocks on a full buffer. stdin
    // stays open on purpose: the server exits when the app closes it.
    proc.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_log, onError: (_) {});
    proc.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_log, onError: (_) {});
  }

  void _detach() {
    _process = null;
    _endpoint = null;
    _exited = true;
  }

  Future<bool> _waitForHealth(int port) async {
    final url = Uri.parse('http://127.0.0.1:$port/healthz');
    final deadline = DateTime.now().add(_healthTimeout);
    while (DateTime.now().isBefore(deadline)) {
      if (_exited) return false;
      try {
        if (await _healthCheck(url)) return true;
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return false;
  }

  static Future<bool> _defaultHealthCheck(Uri url) async {
    try {
      final resp = await http.get(url).timeout(const Duration(seconds: 2));
      if (resp.statusCode != 200) return false;
      // A stolen port could answer 200 for anything; the devinorium health
      // endpoint has a distinctive body.
      final body = jsonDecode(resp.body);
      return body is Map<String, dynamic> && body['status'] == 'ok';
    } catch (_) {
      return false;
    }
  }

  static Future<Process> _defaultSpawn(
    String executable,
    List<String> arguments, {
    required Map<String, String> environment,
    required String workingDirectory,
  }) {
    return Process.start(
      executable,
      arguments,
      environment: environment,
      workingDirectory: workingDirectory,
    );
  }

  void _log(String line) {
    if (kDebugMode) debugPrint('[local-server] $line');
  }
}
