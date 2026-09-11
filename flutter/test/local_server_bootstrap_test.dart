import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/api/api_service.dart';
import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/servers/multi_server_state.dart';
import 'package:devinorium_frontend/servers/server_profile.dart';
import 'package:devinorium_frontend/services/local_server.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeApi extends ApiService {
  _FakeApi()
      : super(
          client: ApiClient.withClient(
            MockClient((_) async => http.Response('{}', 200)),
          ),
        );

  @override
  Future<User> me() async => User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        isOwner: true,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      );

  @override
  Future<List<ProviderInfo>> listProviders() async =>
      [ProviderInfo(id: 'devin-cli', name: 'Devin CLI')];

  @override
  Future<List<ModelInfo>> listModels({String? provider}) async => [
        ModelInfo(
          id: 'glm-5-2',
          label: 'GLM',
          costTier: 'free',
          family: 'glm',
        ),
      ];

  @override
  Future<List<Project>> listProjects({int? limit, int? offset}) async => [];

  @override
  Future<List<Thread>> listThreads({int? limit, int? offset}) async => [];

  @override
  Future<List<ThreadGroup>> listThreadGroups({int? limit, int? offset}) async =>
      [];

  @override
  Future<List<String>> getThreadRuns() async => [];
}

/// A manager whose endpoint is fixed; `supported` controls whether bootstrap
/// touches it at all.
class _FakeLocalManager implements LocalServerController {
  _FakeLocalManager({
    required this.supported,
    this.endpointToReturn,
    this.binaryAvailable = true,
  });

  final bool supported;
  final bool binaryAvailable;
  LocalServerEndpoint? endpointToReturn;
  int ensureCalls = 0;

  @override
  void Function(int exitCode)? onExit;

  @override
  bool get isSupported => supported;

  @override
  bool get hasBinary => supported && binaryAvailable;

  @override
  LocalServerEndpoint? get endpoint => endpointToReturn;

  @override
  Future<LocalServerEndpoint?> ensureRunning() async {
    ensureCalls++;
    return endpointToReturn;
  }

  @override
  Future<void> stop() async {}

  @override
  void dispose() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('bundled local server', () {
    test('bootstrap registers the local profile when the server starts',
        () async {
      final manager = _FakeLocalManager(
        supported: true,
        endpointToReturn: const LocalServerEndpoint(
          baseUrl: 'http://127.0.0.1:43210',
          token: 'tok',
        ),
      );
      final state = AppState.test(
        localServerManager: manager,
        api: null,
      );
      addTearDown(state.dispose);

      await state.bootstrap();

      expect(manager.ensureCalls, 1);
      final profile =
          state.multiServerState.profileById(MultiServerState.localProfileId);
      expect(profile, isNotNull);
      expect(profile!.isLocal, isTrue);
      expect(profile.baseUrl, 'http://127.0.0.1:43210');
      expect(profile.token, 'tok');
      expect(state.activeServerId, MultiServerState.localProfileId);
    });

    test('bootstrap keeps a remote server active when one is configured',
        () async {
      final multi = MultiServerState();
      multi.addTestConnection(
        ServerProfile(
          id: 'remote',
          label: 'remote',
          baseUrl: 'http://remote:7878',
          token: 't',
          username: 'owner',
          createdAt: DateTime(2024, 1, 1).toUtc(),
          isPrimary: true,
        ),
        _FakeApi(),
      );
      final manager = _FakeLocalManager(
        supported: true,
        endpointToReturn: const LocalServerEndpoint(
          baseUrl: 'http://127.0.0.1:43210',
          token: 'tok',
        ),
      );
      final state = AppState.test(
        multiServerState: multi,
        localServerManager: manager,
      );
      addTearDown(state.dispose);

      await state.bootstrap();

      expect(state.activeServerId, 'remote');
      expect(
        multi.profileById(MultiServerState.localProfileId)!.isPrimary,
        isFalse,
      );
      // The remote profile's own api still serves the session.
      expect(state.user?.username, 'owner');
    });

    test('bootstrap drops a stale local profile when no binary is bundled',
        () async {
      final multi = MultiServerState();
      multi.addTestConnection(
        ServerProfile(
          id: MultiServerState.localProfileId,
          label: 'local',
          baseUrl: 'http://127.0.0.1:43210',
          token: 'stale',
          username: 'local',
          createdAt: DateTime(2024, 1, 1).toUtc(),
          isPrimary: true,
          isLocal: true,
        ),
        _FakeApi(),
      );
      final manager =
          _FakeLocalManager(supported: true, binaryAvailable: false);
      final state = AppState.test(
        multiServerState: multi,
        localServerManager: manager,
      );
      addTearDown(state.dispose);

      await state.bootstrap();

      expect(
        multi.profileById(MultiServerState.localProfileId),
        isNull,
      );
    });

    test('bootstrap keeps the local profile on a transient start failure',
        () async {
      final multi = MultiServerState();
      multi.addTestConnection(
        ServerProfile(
          id: MultiServerState.localProfileId,
          label: 'local',
          baseUrl: 'http://127.0.0.1:43210',
          token: 'stale',
          username: 'local',
          createdAt: DateTime(2024, 1, 1).toUtc(),
          isPrimary: true,
          isLocal: true,
        ),
        _FakeApi(),
      );
      // Binary present, but ensureRunning could not get a healthy server.
      final manager = _FakeLocalManager(supported: true);
      final state = AppState.test(
        multiServerState: multi,
        localServerManager: manager,
      );
      addTearDown(state.dispose);

      await state.bootstrap();

      expect(
        multi.profileById(MultiServerState.localProfileId),
        isNotNull,
      );
    });

    test('switchServer back to the local profile re-ensures the server',
        () async {
      final multi = MultiServerState();
      multi.addTestConnection(
        ServerProfile(
          id: 'remote',
          label: 'remote',
          baseUrl: 'http://remote:7878',
          token: 't',
          username: 'owner',
          createdAt: DateTime(2024, 1, 1).toUtc(),
          isPrimary: true,
        ),
        _FakeApi(),
      );
      final manager = _FakeLocalManager(
        supported: true,
        endpointToReturn: const LocalServerEndpoint(
          baseUrl: 'http://127.0.0.1:43210',
          token: 'tok',
        ),
      );
      final state = AppState.test(
        multiServerState: multi,
        localServerManager: manager,
      );
      addTearDown(state.dispose);
      await state.bootstrap();
      expect(state.activeServerId, 'remote');
      final callsAfterBoot = manager.ensureCalls;

      // The stored local endpoint is stale; switching must re-ensure first.
      await state.switchServer(MultiServerState.localProfileId);

      expect(state.activeServerId, MultiServerState.localProfileId);
      expect(manager.ensureCalls, greaterThan(callsAfterBoot));
    });

    test('unsupported platforms never touch the manager', () async {
      final manager = _FakeLocalManager(supported: false);
      final state = AppState.test(
        localServerManager: manager,
        api: null,
      );
      addTearDown(state.dispose);

      await state.bootstrap();

      expect(manager.ensureCalls, 0);
      expect(state.multiServerState.hasAnyServer, isFalse);
    });

    test('an unexpected exit while active re-registers a fresh endpoint',
        () async {
      final manager = _FakeLocalManager(
        supported: true,
        endpointToReturn: const LocalServerEndpoint(
          baseUrl: 'http://127.0.0.1:43210',
          token: 'tok',
        ),
      );
      final state = AppState.test(
        localServerManager: manager,
        api: null,
      );
      addTearDown(state.dispose);
      await state.bootstrap();
      expect(state.activeServerId, MultiServerState.localProfileId);

      // Second ensure returns the rotated endpoint.
      manager.endpointToReturn = const LocalServerEndpoint(
        baseUrl: 'http://127.0.0.1:45678',
        token: 'tok2',
      );
      manager.onExit?.call(1);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // The dead endpoint also fails the next health check, which re-runs
      // ensure again — all paths converge on re-registering the server.
      expect(manager.ensureCalls, greaterThanOrEqualTo(2));
      expect(
        state.multiServerState
            .profileById(MultiServerState.localProfileId)!
            .baseUrl,
        'http://127.0.0.1:45678',
      );
    });

    test('an exit while a remote server is active does not restart',
        () async {
      final multi = MultiServerState();
      multi.addTestConnection(
        ServerProfile(
          id: 'remote',
          label: 'remote',
          baseUrl: 'http://remote:7878',
          token: 't',
          username: 'owner',
          createdAt: DateTime(2024, 1, 1).toUtc(),
          isPrimary: true,
        ),
        _FakeApi(),
      );
      final manager = _FakeLocalManager(
        supported: true,
        endpointToReturn: const LocalServerEndpoint(
          baseUrl: 'http://127.0.0.1:43210',
          token: 'tok',
        ),
      );
      final state = AppState.test(
        multiServerState: multi,
        localServerManager: manager,
      );
      addTearDown(state.dispose);
      await state.bootstrap();
      expect(state.activeServerId, 'remote');

      manager.onExit?.call(1);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(manager.ensureCalls, 1);
    });
  });
}
