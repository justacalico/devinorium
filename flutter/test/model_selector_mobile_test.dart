import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/api/api_service.dart';
import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:devinorium_frontend/views/thread_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _ThrowingClient implements BaseApiClient {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _ModelsApi extends ApiService {
  _ModelsApi() : super(client: _ThrowingClient());

  final requestedProviders = <String?>[];
  String? lastSettingsProvider;
  String? lastSettingsModel;
  List<ModelInfo> modelsToReturn = const [];

  @override
  Future<List<ModelInfo>> listModels({String? provider}) {
    requestedProviders.add(provider);
    return Future.value(modelsToReturn);
  }

  @override
  Future<List<Thread>> listThreads({int? limit, int? offset}) =>
      Future.value(const []);

  @override
  Future<List<ThreadGroup>> listThreadGroups({int? limit, int? offset}) =>
      Future.value(const []);

  @override
  Future<List<String>> getThreadRuns() => Future.value(const []);

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
    lastSettingsModel = model;
    return Future.value();
  }
}

AppState _buildState({
  ApiService? api,
  String? devinSessionId,
  List<ProviderInfo>? providers,
  String selectedProvider = 'devin-cli',
}) {
  return AppState.test(
    api: api,
    user: User(
      id: 1,
      username: 'owner',
      role: 'user',
      totpEnabled: false,
      isOwner: true,
      providerId: 'devin-cli',
      providerCommand: 'devin',
    ),
    providers:
        providers ??
        [
          ProviderInfo(id: 'devin-cli', name: 'Devin CLI'),
          ProviderInfo(id: 'opencode', name: 'OpenCode'),
          ProviderInfo(id: 'codex', name: 'Codex CLI'),
        ],
    models: [
      ModelInfo(id: 'm1', label: 'Model 1', costTier: 'free', family: 'f'),
    ],
    selectedProvider: selectedProvider,
    selectedModel: 'm1',
    selectedPermission: 'normal',
    activeThreadId: 't1',
    activeThreadDetail: ThreadDetail(
      thread: Thread(
        id: 't1',
        title: 'Test thread',
        projectId: 1,
        model: 'm1',
        permissionMode: 'normal',
        devinSessionId: devinSessionId,
        createdAt: '',
        updatedAt: '',
      ),
      messages: const [],
    ),
  );
}

Widget _wrap(AppState state) => MaterialApp(
  home: ChangeNotifierProvider<AppState>.value(
    value: state,
    child: const ThreadPage(),
  ),
);

void _usePhoneSize(WidgetTester tester) {
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1.0;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('shows a labelled provider dropdown on narrow screens', (
    tester,
  ) async {
    _usePhoneSize(tester);
    final api = _ModelsApi()
      ..modelsToReturn = [
        ModelInfo(id: 'm1', label: 'Model 1', costTier: 'free', family: 'f'),
      ];
    final state = _buildState(api: api);
    addTearDown(state.dispose);

    await tester.pumpWidget(_wrap(state));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('model_selector')));
    await tester.pumpAndSettle();

    final dropdown = find.byKey(const Key('mobile_provider_dropdown'));
    expect(dropdown, findsOneWidget);
    expect(
      find.descendant(of: dropdown, matching: find.text('Devin CLI')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('provider_rail')), findsNothing);
  });

  testWidgets('selecting a provider from the dropdown updates the selection', (
    tester,
  ) async {
    _usePhoneSize(tester);
    final api = _ModelsApi()
      ..modelsToReturn = [
        ModelInfo(
          id: 'oc-m1',
          label: 'OC Model 1',
          costTier: 'free',
          family: 'f',
        ),
      ];
    final state = _buildState(api: api);
    addTearDown(state.dispose);

    await tester.pumpWidget(_wrap(state));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('model_selector')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('mobile_provider_dropdown')));
    await tester.pumpAndSettle();

    final selectedMenuItem = find.ancestor(
      of: find.text('Devin CLI'),
      matching: find.byType(MenuItemButton),
    );
    expect(
      find.descendant(of: selectedMenuItem, matching: find.byIcon(Icons.check)),
      findsOneWidget,
    );

    await tester.tap(find.text('OpenCode'));
    await tester.pumpAndSettle();

    expect(state.selectedProvider, 'opencode');
    expect(api.requestedProviders, contains('opencode'));
    // saveThreadSettings runs after the provider switch finished, so the
    // persisted model is one the new provider actually offers.
    expect(api.lastSettingsProvider, 'opencode');
    expect(api.lastSettingsModel, 'oc-m1');
  });

  testWidgets('provider dropdown is disabled while the thread is locked', (
    tester,
  ) async {
    _usePhoneSize(tester);
    final api = _ModelsApi()
      ..modelsToReturn = [
        ModelInfo(id: 'm1', label: 'Model 1', costTier: 'free', family: 'f'),
      ];
    final state = _buildState(api: api, devinSessionId: 'sess-1');
    addTearDown(state.dispose);

    await tester.pumpWidget(_wrap(state));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('model_selector')));
    await tester.pumpAndSettle();

    final inkWell = tester.widget<InkWell>(
      find.byKey(const Key('mobile_provider_dropdown')),
    );
    expect(inkWell.onTap, isNull);

    await tester.tap(find.byKey(const Key('mobile_provider_dropdown')));
    await tester.pumpAndSettle();

    expect(find.byType(MenuItemButton), findsNothing);
    expect(state.selectedProvider, 'devin-cli');
  });

  testWidgets('keeps the provider rail on wide screens', (tester) async {
    final api = _ModelsApi()
      ..modelsToReturn = [
        ModelInfo(id: 'm1', label: 'Model 1', costTier: 'free', family: 'f'),
      ];
    final state = _buildState(api: api);
    addTearDown(state.dispose);

    await tester.pumpWidget(_wrap(state));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('model_selector')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('provider_rail')), findsOneWidget);
    expect(find.byKey(const Key('mobile_provider_dropdown')), findsNothing);
  });

  testWidgets('hides the selector when there is a single provider', (
    tester,
  ) async {
    _usePhoneSize(tester);
    final api = _ModelsApi()
      ..modelsToReturn = [
        ModelInfo(id: 'm1', label: 'Model 1', costTier: 'free', family: 'f'),
      ];
    final state = _buildState(
      api: api,
      providers: [ProviderInfo(id: 'devin-cli', name: 'Devin CLI')],
    );
    addTearDown(state.dispose);

    await tester.pumpWidget(_wrap(state));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('model_selector')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('mobile_provider_dropdown')), findsNothing);
    expect(find.byKey(const Key('provider_rail')), findsNothing);
  });

  testWidgets('shows the current provider name even when it is unknown', (
    tester,
  ) async {
    _usePhoneSize(tester);
    final api = _ModelsApi()
      ..modelsToReturn = [
        ModelInfo(id: 'm1', label: 'Model 1', costTier: 'free', family: 'f'),
      ];
    final state = _buildState(api: api, selectedProvider: 'custom-cli');
    addTearDown(state.dispose);

    await tester.pumpWidget(_wrap(state));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('model_selector')));
    await tester.pumpAndSettle();

    final dropdown = find.byKey(const Key('mobile_provider_dropdown'));
    expect(dropdown, findsOneWidget);
    expect(
      find.descendant(of: dropdown, matching: find.text('custom-cli')),
      findsOneWidget,
    );
  });
}
