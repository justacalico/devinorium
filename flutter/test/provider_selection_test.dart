import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/api/api_service.dart';
import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter_test/flutter_test.dart';

class _ThrowingClient implements BaseApiClient {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// ApiService that records the provider arguments it receives.
class _ProviderApi extends ApiService {
  _ProviderApi() : super(client: _ThrowingClient());

  String? lastCreateProvider;
  String? lastSettingsProvider;
  final modelsProviders = <String?>[];
  List<ModelInfo> modelsToReturn = const [];
  String threadProviderId = 'devin-cli';
  Thread? createdThread;

  Thread _thread() =>
      createdThread ??
      Thread(
        id: 't-new',
        title: 'New thread',
        projectId: 1,
        providerId: threadProviderId,
        model: '',
        permissionMode: 'normal',
        createdAt: '',
        updatedAt: '',
      );

  @override
  Future<Thread> createThread({
    required int projectId,
    String? title,
    int? threadGroupId,
    String? provider,
    String? model,
    String? permissionMode,
    String? permissions,
    String? branch,
    String? worktreePath,
  }) {
    lastCreateProvider = provider;
    return Future.value(_thread());
  }

  @override
  Future<ThreadDetail> getThread(
    String id, {
    bool includeMessages = false,
    int? turnLimit,
  }) {
    return Future.value(
      ThreadDetail(
        thread: Thread(
          id: id,
          title: 't',
          projectId: 1,
          providerId: threadProviderId,
          model: '',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '',
        ),
        messages: const [],
        totalMessages: 0,
      ),
    );
  }

  @override
  Future<Map<String, dynamic>> getThreadProject(String id) =>
      Future.value({'project_id': 1});

  @override
  Future<List<Thread>> listThreads({int? limit, int? offset}) =>
      Future.value(const []);

  @override
  Future<List<ThreadGroup>> listThreadGroups({int? limit, int? offset}) =>
      Future.value(const []);

  @override
  Future<List<String>> getThreadRuns() => Future.value(const []);

  @override
  Future<List<ModelInfo>> listModels({String? provider}) {
    modelsProviders.add(provider);
    return Future.value(modelsToReturn);
  }

  @override
  Future<void> updateThreadSettings(
    String id, {
    String? provider,
    String? model,
    String? permissionMode,
    String? permissions,
  }) {
    lastSettingsProvider = provider;
    return Future.value();
  }
}

void main() {
  setUp(() {
    if (kDebugMode) debugPrint = (String? message, {int? wrapWidth}) {};
  });

  test('selectedProvider falls back to the user provider', () {
    final user = User(
      id: 1,
      username: 'owner',
      role: 'user',
      totpEnabled: false,
      providerId: 'opencode',
      providerCommand: 'opencode',
    );
    final state = AppState.test(user: user);
    addTearDown(state.dispose);

    expect(state.selectedProvider, 'opencode');
  });

  test('createNewThread passes the selected provider', () async {
    final api = _ProviderApi()..threadProviderId = 'opencode';
    final state = AppState.test(
      api: api,
      selectedProvider: 'opencode',
      projects: [
        Project(id: 1, name: 'p', path: '/tmp/p', createdAt: '', updatedAt: ''),
      ],
      activeProjectId: 1,
    );
    addTearDown(state.dispose);

    await state.createNewThread();

    expect(api.lastCreateProvider, 'opencode');
    expect(state.selectedProvider, 'opencode');
  });

  test('opening a thread seeds its provider and loads its models', () async {
    final api = _ProviderApi()
      ..threadProviderId = 'opencode'
      ..modelsToReturn = [
        ModelInfo(id: 'oc-m1', label: 'm1', costTier: 'free', family: 'f'),
      ];
    final state = AppState.test(api: api);
    addTearDown(state.dispose);

    await state.openThread('t1');

    expect(state.selectedProvider, 'opencode');
    expect(api.modelsProviders, contains('opencode'));
    expect(state.models.map((m) => m.id), contains('oc-m1'));
    // The thread has no model yet, so the provider's first model applies.
    expect(state.selectedModel, 'oc-m1');
  });

  test('re-selecting the same provider still fixes an invalid model', () async {
    final api = _ProviderApi()
      ..modelsToReturn = [
        ModelInfo(id: 'oc-m1', label: 'm1', costTier: 'free', family: 'f'),
      ];
    final state = AppState.test(
      api: api,
      selectedProvider: 'opencode',
      selectedModel: 'devin-model',
    );
    addTearDown(state.dispose);

    // First fetch primes the catalog for the provider.
    await state.setSelectedProvider('opencode');
    expect(state.selectedModel, 'oc-m1');

    // A stale selection is corrected without another fetch.
    state.setSelectedModel('devin-model');
    await state.ensureModelsFor('opencode');
    expect(state.selectedModel, 'oc-m1');
    expect(
      api.modelsProviders.where((p) => p == 'opencode').length,
      1,
    );
  });

  test('changing provider refreshes models and fixes invalid model', () async {
    final api = _ProviderApi()
      ..modelsToReturn = [
        ModelInfo(id: 'oc-m1', label: 'm1', costTier: 'free', family: 'f'),
        ModelInfo(id: 'oc-m2', label: 'm2', costTier: 'free', family: 'f'),
      ];
    final state = AppState.test(
      api: api,
      selectedProvider: 'devin-cli',
      selectedModel: 'devin-model',
    );
    addTearDown(state.dispose);

    await state.setSelectedProvider('opencode');

    expect(api.modelsProviders, contains('opencode'));
    expect(state.selectedModel, 'oc-m1');
  });

  test('saveThreadSettings sends the thread provider', () async {
    final api = _ProviderApi()..threadProviderId = 'opencode';
    final state = AppState.test(api: api);
    addTearDown(state.dispose);

    await state.openThread('t1');
    api.lastSettingsProvider = null;
    await state.saveThreadSettings();

    expect(api.lastSettingsProvider, 'opencode');
  });
}
