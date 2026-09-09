import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/api/api_service.dart';
import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_test/flutter_test.dart';

class _ThrowingClient implements BaseApiClient {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// ApiService that records the provider arguments it receives.
class _ProviderApi extends ApiService {
  _ProviderApi() : super(client: _ThrowingClient());

  String? lastCreateProvider;
  String? lastCreateModel;
  String? lastCreatePermission;
  String? lastCreateReasoning;
  String? lastSettingsProvider;
  String? lastSettingsReasoning;
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
    String? reasoningEffort,
    String? permissions,
    String? branch,
    String? worktreePath,
    String? envMode,
  }) {
    lastCreateProvider = provider;
    lastCreateModel = model;
    lastCreatePermission = permissionMode;
    lastCreateReasoning = reasoningEffort;
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
        thread:
            createdThread ??
            Thread(
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
    String? reasoningEffort,
    String? permissions,
    String? envMode,
  }) {
    lastSettingsProvider = provider;
    lastSettingsReasoning = reasoningEffort;
    return Future.value();
  }
}

void main() {
  setUp(() {
    if (kDebugMode) debugPrint = (String? message, {int? wrapWidth}) {};
    SharedPreferences.setMockInitialValues({});
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

  test('createNewThread passes the selected model and permission', () async {
    final api = _ProviderApi()
      ..threadProviderId = 'opencode'
      ..modelsToReturn = [
        ModelInfo(id: 'oc-m1', label: 'm1', costTier: 'free', family: 'f'),
      ];
    final state = AppState.test(
      api: api,
      selectedProvider: 'opencode',
      selectedModel: 'oc-m1',
      selectedPermission: 'bypass',
      projects: [
        Project(id: 1, name: 'p', path: '/tmp/p', createdAt: '', updatedAt: ''),
      ],
      activeProjectId: 1,
    );
    addTearDown(state.dispose);

    await state.createNewThread();

    expect(api.lastCreateProvider, 'opencode');
    expect(api.lastCreateModel, 'oc-m1');
    expect(api.lastCreatePermission, 'bypass');
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
    expect(api.modelsProviders.where((p) => p == 'opencode').length, 1);
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

  test('setSelectedModel persists the selected model', () async {
    final state = AppState.test();
    addTearDown(state.dispose);

    state.setSelectedModel('glm-5-2');
    await Future.delayed(Duration.zero);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('devinorium_selected_model'), 'glm-5-2');
  });

  test('setSelectedPermission persists the selected permission', () async {
    final state = AppState.test();
    addTearDown(state.dispose);

    state.setSelectedPermission('bypass');
    await Future.delayed(Duration.zero);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('devinorium_selected_permission'), 'bypass');
  });

  test(
    'setSelectedProvider persists the selected provider and model',
    () async {
      final api = _ProviderApi()
        ..modelsToReturn = [
          ModelInfo(id: 'oc-m1', label: 'm1', costTier: 'free', family: 'f'),
        ];
      final state = AppState.test(api: api, selectedProvider: 'opencode');
      addTearDown(state.dispose);

      await state.setSelectedProvider('opencode');
      await Future.delayed(Duration.zero);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('devinorium_selected_provider'), 'opencode');
      expect(prefs.getString('devinorium_selected_model'), 'oc-m1');
    },
  );

  test('setSelectedProvider persists while a thread is active', () async {
    final api = _ProviderApi()
      ..threadProviderId = 'opencode'
      ..modelsToReturn = [
        ModelInfo(id: 'oc-m1', label: 'm1', costTier: 'free', family: 'f'),
      ];
    final state = AppState.test(api: api);
    addTearDown(state.dispose);

    await state.openThread('t1');
    await state.setSelectedProvider('opencode');
    await Future.delayed(Duration.zero);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('devinorium_selected_provider'), 'opencode');
    expect(prefs.getString('devinorium_selected_model'), 'oc-m1');
  });

  test('setSelectedModel persists while a thread is active', () async {
    final api = _ProviderApi()
      ..threadProviderId = 'devin-cli'
      ..modelsToReturn = [
        ModelInfo(id: 'glm-5-2', label: 'GLM', costTier: 'free', family: 'f'),
      ];
    final state = AppState.test(api: api);
    addTearDown(state.dispose);

    await state.openThread('t1');
    state.setSelectedModel('glm-5-2');
    await Future.delayed(Duration.zero);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('devinorium_selected_model'), 'glm-5-2');
  });

  test('setSelectedPermission persists while a thread is active', () async {
    final api = _ProviderApi()..threadProviderId = 'devin-cli';
    final state = AppState.test(api: api);
    addTearDown(state.dispose);

    await state.openThread('t1');
    state.setSelectedPermission('bypass');
    await Future.delayed(Duration.zero);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('devinorium_selected_permission'), 'bypass');
  });

  test(
    'setSelectedProvider clears persisted model when catalog is empty',
    () async {
      final api = _ProviderApi()
        ..modelsToReturn = []
        ..threadProviderId = 'devin-cli';
      SharedPreferences.setMockInitialValues({
        'devinorium_selected_provider': 'devin-cli',
        'devinorium_selected_model': 'stale-model',
      });
      final state = AppState.test(api: api, selectedProvider: 'devin-cli');
      addTearDown(state.dispose);

      await state.setSelectedProvider('opencode');
      await Future.delayed(Duration.zero);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('devinorium_selected_provider'), 'opencode');
      expect(prefs.getString('devinorium_selected_model'), isNull);
      expect(state.selectedModel, '');
    },
  );

  test('createNewThread passes the selected reasoning effort', () async {
    final api = _ProviderApi()
      ..threadProviderId = 'codex'
      ..modelsToReturn = [
        ModelInfo(
          id: 'gpt-5.4-terra',
          label: 'GPT-5.4-Terra',
          costTier: 'high',
          family: 'gpt',
          defaultReasoningEffort: 'medium',
          supportedReasoningEfforts: const ['low', 'medium', 'high', 'xhigh'],
        ),
      ];
    final state = AppState.test(
      api: api,
      selectedProvider: 'codex',
      selectedModel: 'gpt-5.4-terra',
      selectedReasoning: 'high',
      projects: [
        Project(id: 1, name: 'p', path: '/tmp/p', createdAt: '', updatedAt: ''),
      ],
      activeProjectId: 1,
    );
    addTearDown(state.dispose);

    await state.createNewThread();

    expect(api.lastCreateProvider, 'codex');
    expect(api.lastCreateModel, 'gpt-5.4-terra');
    expect(api.lastCreateReasoning, 'high');
  });

  test('changing the model revalidates the reasoning effort', () {
    final state = AppState.test(
      selectedModel: 'm1',
      selectedReasoning: 'low',
      models: [
        ModelInfo(
          id: 'm1',
          label: 'm1',
          costTier: 'free',
          family: 'f',
          defaultReasoningEffort: 'low',
          supportedReasoningEfforts: const ['low', 'medium'],
        ),
        ModelInfo(
          id: 'm2',
          label: 'm2',
          costTier: 'free',
          family: 'f',
          defaultReasoningEffort: 'medium',
          supportedReasoningEfforts: const ['medium', 'high'],
        ),
      ],
    );
    addTearDown(state.dispose);

    state.setSelectedModel('m2');

    expect(state.selectedModel, 'm2');
    expect(state.selectedReasoning, 'medium');
  });

  test('setSelectedReasoning persists the effort', () async {
    final state = AppState.test();
    addTearDown(state.dispose);

    state.setSelectedReasoning('high');
    await Future.delayed(Duration.zero);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('devinorium_selected_reasoning'), 'high');
  });

  test('switching provider reuses cached model catalog', () async {
    final api = _ProviderApi()
      ..modelsToReturn = [
        ModelInfo(id: 'm1', label: 'm1', costTier: 'free', family: 'f'),
      ];
    final state = AppState.test(
      api: api,
      selectedProvider: 'devin-cli',
      providers: [
        ProviderInfo(id: 'devin-cli', name: 'Devin CLI'),
        ProviderInfo(id: 'opencode', name: 'OpenCode'),
        ProviderInfo(id: 'codex', name: 'Codex'),
      ],
    );
    addTearDown(state.dispose);

    await state.setSelectedProvider('opencode');
    await state.setSelectedProvider('codex');
    await state.setSelectedProvider('opencode');
    await state.setSelectedProvider('devin-cli');
    await state.setSelectedProvider('codex');

    // Each unique provider should only be fetched once.
    expect(api.modelsProviders, ['opencode', 'codex', 'devin-cli']);
  });

  test('saveThreadSettings sends the thread reasoning effort', () async {
    final api = _ProviderApi()
      ..threadProviderId = 'codex'
      ..createdThread = Thread(
        id: 't1',
        title: 't',
        projectId: 1,
        providerId: 'codex',
        model: 'gpt-5.4-terra',
        permissionMode: 'normal',
        reasoningEffort: 'high',
        createdAt: '',
        updatedAt: '',
      )
      ..modelsToReturn = [
        ModelInfo(
          id: 'gpt-5.4-terra',
          label: 'GPT-5.4-Terra',
          costTier: 'high',
          family: 'gpt',
          defaultReasoningEffort: 'medium',
          supportedReasoningEfforts: const ['low', 'medium', 'high'],
        ),
      ];
    final state = AppState.test(api: api);
    addTearDown(state.dispose);

    await state.openThread('t1');
    await state.saveThreadSettings();

    expect(api.lastSettingsProvider, 'codex');
    expect(api.lastSettingsReasoning, 'high');
  });
}
