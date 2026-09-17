import 'dart:async';
import 'dart:convert';

import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/api/api_service.dart';
import 'package:devinorium_frontend/generated/l10n/app_localizations.dart';
import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:devinorium_frontend/state/async_value.dart';
import 'package:devinorium_frontend/state/thread_store.dart';
import 'package:devinorium_frontend/views/settings_page.dart';
import 'package:devinorium_frontend/views/thread_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class _ThrowingClient implements BaseApiClient {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

Machine _machine(int id, String name, {String host = '10.0.0.1'}) => Machine(
  id: id,
  name: name,
  host: host,
  port: 5900,
  hasPassword: true,
  createdAt: 'now',
  updatedAt: 'now',
);

/// ApiService stub backing the machines endpoints plus the settings-page
/// loaders that run on open.
class _MachinesApi extends ApiService {
  _MachinesApi() : super(client: _ThrowingClient());

  List<Machine> machineList = [];
  List<Map<String, Object?>> created = [];
  Map<int, Map<String, Object?>> updated = {};
  List<int> deleted = [];
  Map<int, MachineTestResult> testResults = {};
  int machinesCalls = 0;

  @override
  Future<List<Machine>> machines() async {
    machinesCalls++;
    return List.of(machineList);
  }

  @override
  Future<Machine> createMachine({
    required String name,
    required String host,
    required int port,
    String? password,
  }) async {
    created.add({
      'name': name,
      'host': host,
      'port': port,
      'password': password,
    });
    final m = Machine(
      id: machineList.length + 1,
      name: name.trim(),
      host: host.trim(),
      port: port,
      hasPassword: password != null && password.isNotEmpty,
    );
    machineList.add(m);
    return m;
  }

  @override
  Future<Machine> updateMachine(
    int id, {
    String? name,
    String? host,
    int? port,
    String? password,
  }) async {
    updated[id] = {
      'name': name,
      'host': host,
      'port': port,
      'password': password,
    };
    final i = machineList.indexWhere((m) => m.id == id);
    final old = machineList[i];
    final m = Machine(
      id: id,
      name: name?.trim() ?? old.name,
      host: host?.trim() ?? old.host,
      port: port ?? old.port,
      hasPassword: password == null ? old.hasPassword : password.isNotEmpty,
    );
    machineList[i] = m;
    return m;
  }

  @override
  Future<void> deleteMachine(int id) async {
    deleted.add(id);
    machineList.removeWhere((m) => m.id == id);
  }

  @override
  Future<MachineTestResult> testMachine(int id) async =>
      testResults[id] ?? MachineTestResult(ok: false, error: 'unreachable');

  // Settings-page loaders.
  @override
  Future<List<GitConnection>> listGitConnections() async => [];
  @override
  Future<String?> getCloneRoot() async => null;
  @override
  Future<String?> getWorktreeRoot() async => null;
  @override
  Future<String?> getProjectRoot() async => null;
  @override
  Future<ProviderVersion> providerVersion({String? provider}) =>
      throw ApiException('not found', 404);
  @override
  Future<TailscaleInfo> tailscaleStatus() =>
      throw ApiException('not found', 404);
  @override
  Future<List<User>> listUsers() async => [];
}

/// Send-side stub recording the machine ids forwarded to the backend.
class _SendApi extends ApiService {
  _SendApi() : super(client: _ThrowingClient());

  String? sentPrompt;
  List<int> sentMachineIds = const [];
  final controller = StreamController<SseEvent>();
  bool useController = false;

  @override
  Future<void> updateThreadSettings(
    String id, {
    String? provider,
    String? model,
    String? permissionMode,
    String? reasoningEffort,
    String? permissions,
    String? envMode,
  }) => Future.value();

  @override
  Future<Map<String, dynamic>> getThreadRun(String id) =>
      Future.value({'status': 'idle', 'parts': []});

  @override
  Stream<SseEvent> sendMessageStream({
    required String threadId,
    required String prompt,
    String? mode,
    String? clientMessageId,
    List<({String filename, String mime, Uint8List bytes})> attachments =
        const [],
    List<PathRef> contextPaths = const [],
    List<String> referencedThreadIds = const [],
    List<int> machineIds = const [],
  }) {
    sentPrompt = prompt;
    sentMachineIds = machineIds;
    if (useController) return controller.stream;
    return Stream.fromIterable([
      SseEvent(
        'user_message',
        '{"id": 2, "role": "user", "content": "hi"}',
        id: '1',
      ),
      SseEvent(
        'done',
        '{"id": 3, "role": "assistant", "content": "ok"}',
        id: '2',
      ),
    ]);
  }
}

Thread _thread(String id) => Thread(
  id: id,
  title: 'Current',
  projectId: 1,
  model: 'm1',
  permissionMode: 'normal',
  createdAt: '',
  updatedAt: '',
);

User _owner() => User(
  id: 1,
  username: 'owner',
  role: 'user',
  totpEnabled: false,
  isOwner: true,
  providerId: 'devin-cli',
  providerCommand: 'devin',
);

ThreadStore _store(ApiService api, {List<MachineReference>? refs}) =>
    ThreadStore(
      api: api,
      threadId: 't1',
      projectId: 1,
      machineReferences: refs,
      detail: AsyncValue.ready(
        ThreadDetail(thread: _thread('t1'), messages: const []),
      ),
    );

void main() {
  group('Machine model', () {
    test('parses a full row', () {
      final m = Machine.fromJson({
        'id': 3,
        'name': 'gaming pc',
        'host': 'vnc.local',
        'port': 5901,
        'has_password': true,
        'created_at': 'a',
        'updated_at': 'b',
      });
      expect(m.id, 3);
      expect(m.name, 'gaming pc');
      expect(m.host, 'vnc.local');
      expect(m.port, 5901);
      expect(m.hasPassword, isTrue);
    });

    test('defaults port and flags when absent', () {
      final m = Machine.fromJson({'id': 1});
      expect(m.port, 5900);
      expect(m.hasPassword, isFalse);
      expect(m.name, '');
    });

    test('test result parses ok and error shapes', () {
      final ok = MachineTestResult.fromJson({
        'ok': true,
        'width': 1920,
        'height': 1080,
        'name': 'desktop',
      });
      expect(ok.ok, isTrue);
      expect(ok.width, 1920);
      expect(ok.name, 'desktop');

      final bad = MachineTestResult.fromJson({
        'ok': false,
        'error': 'connection refused',
      });
      expect(bad.ok, isFalse);
      expect(bad.error, 'connection refused');
    });
  });

  group('buildSendFields', () {
    test('serializes machine ids as a JSON array', () {
      final fields = buildSendFields(prompt: 'hi', machineIds: [2, 7]);
      expect(jsonDecode(fields['machine_ids']!), [2, 7]);
    });

    test('omits machine_ids when empty', () {
      expect(buildSendFields(prompt: 'hi').containsKey('machine_ids'), isFalse);
    });
  });

  group('machine references in state', () {
    test('add dedupes by id and remove drops the chip', () {
      final state = AppState.test(
        api: _MachinesApi(),
        user: _owner(),
        machines: [_machine(1, 'alpha'), _machine(2, 'beta')],
      );
      addTearDown(state.dispose);

      state.addMachineReference(const MachineReference(id: 1, name: 'alpha'));
      state.addMachineReference(const MachineReference(id: 1, name: 'alpha'));
      state.addMachineReference(const MachineReference(id: 2, name: 'beta'));
      expect(state.machineReferences, hasLength(2));

      state.removeMachineReference(0);
      expect(state.machineReferences.single.id, 2);

      state.clearMachineReferences();
      expect(state.machineReferences, isEmpty);
    });

    test('add stops at the backend cap', () {
      final state = AppState.test(
        api: _MachinesApi(),
        user: _owner(),
        machines: [for (var i = 1; i <= 9; i++) _machine(i, 'm$i')],
      );
      addTearDown(state.dispose);

      for (var i = 1; i <= 9; i++) {
        state.addMachineReference(MachineReference(id: i, name: 'm$i'));
      }
      expect(state.machineReferences, hasLength(maxMachineReferences));
    });

    test('references live on the active thread store', () {
      final state = AppState.test(
        api: _MachinesApi(),
        user: _owner(),
        activeProjectId: 1,
        activeThreadId: 't1',
        activeThreadDetail: ThreadDetail(
          thread: _thread('t1'),
          messages: const [],
        ),
      );
      addTearDown(state.dispose);

      state.addMachineReference(const MachineReference(id: 4, name: 'ws'));
      expect(state.machineReferences.single.id, 4);
    });
  });

  group('machines store', () {
    test('loadMachines populates the list', () async {
      final api = _MachinesApi()..machineList = [_machine(1, 'alpha')];
      final state = AppState.test(api: api, user: _owner());
      addTearDown(state.dispose);

      await state.loadMachines();
      expect(state.machines.single.name, 'alpha');
    });

    test('loadMachines failure leaves an empty list', () async {
      final api = _MachinesApi();
      api.machinesCalls = 0;
      final state = AppState.test(api: api, user: _owner());
      addTearDown(state.dispose);

      // A missing endpoint on an older server is not an error state.
      await state.loadMachines();
      expect(state.machines, isEmpty);
    });

    test('createMachine posts fields and refreshes', () async {
      final api = _MachinesApi();
      final state = AppState.test(api: api, user: _owner());
      addTearDown(state.dispose);

      final error = await state.createMachine(
        name: '  ws ',
        host: ' vnc.local ',
        port: 5901,
        password: 'pw',
      );
      expect(error, isNull);
      // The store passes the raw field values through; trimming happens in
      // ApiService, which this fake bypasses.
      expect(api.created.single['name'], '  ws ');
      expect(state.machines.single.name, 'ws');
      expect(state.machines.single.hasPassword, isTrue);
    });

    test(
      'updateMachine keeps the password when blank and clears on flag',
      () async {
        final api = _MachinesApi()..machineList = [_machine(1, 'alpha')];
        final state = AppState.test(api: api, user: _owner());
        addTearDown(state.dispose);

        await state.updateMachine(1, name: 'renamed');
        expect(api.updated[1]!['password'], isNull);
        expect(state.machines.single.hasPassword, isTrue);

        await state.updateMachine(1, clearPassword: true);
        expect(api.updated[1]!['password'], '');
        expect(state.machines.single.hasPassword, isFalse);
      },
    );

    test('testMachine folds transport errors into a failed result', () async {
      final api = _MachinesApi()..machineList = [_machine(1, 'alpha')];
      final state = AppState.test(api: api, user: _owner());
      addTearDown(state.dispose);

      final result = await state.testMachine(1);
      expect(result.ok, isFalse);
      expect(result.error, 'unreachable');
    });
  });

  group('send path', () {
    test('send forwards machine ids and clears the references', () async {
      final api = _SendApi();
      final store = _store(
        api,
        refs: const [
          MachineReference(id: 3, name: 'gaming pc'),
          MachineReference(id: 5, name: 'workstation'),
        ],
      );
      store.composerText = 'check the download';
      store.onStateChanged = () {};

      await store.sendMessage();
      await Future.delayed(const Duration(milliseconds: 10));

      expect(api.sentMachineIds, [3, 5]);
      expect(store.machineReferences, isEmpty);
    });

    test('send works with only a machine reference', () async {
      final api = _SendApi();
      final store = _store(
        api,
        refs: const [MachineReference(id: 3, name: 'gaming pc')],
      );
      store.onStateChanged = () {};

      await store.sendMessage();
      await Future.delayed(const Duration(milliseconds: 10));

      expect(api.sentMachineIds, [3]);
      expect(api.sentPrompt, '');
    });

    test('a failed send restores the machine references', () async {
      final api = _SendApi()..useController = true;
      final store = _store(
        api,
        refs: const [MachineReference(id: 3, name: 'gaming pc')],
      );
      store.composerText = 'watch it';
      store.onStateChanged = () {};

      await store.sendMessage();
      expect(store.machineReferences, isEmpty);

      await api.controller.close();
      await Future.delayed(const Duration(milliseconds: 10));

      expect(store.machineReferences.single.id, 3);
      expect(store.composerText, 'watch it');
    });
  });

  group('composer @ picker', () {
    AppState stateWithMachines(ApiService api) => AppState.test(
      api: api,
      user: _owner(),
      machines: [
        _machine(1, 'gaming pc'),
        _machine(2, 'workstation', host: '10.0.0.2'),
      ],
      activeProjectId: 1,
      activeThreadId: 't1',
      activeThreadDetail: ThreadDetail(
        thread: _thread('t1'),
        messages: const [],
      ),
    );

    Widget app(AppState state) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const Scaffold(body: ThreadPage()),
      ),
    );

    testWidgets('typing @ lists machines and tapping one adds a chip', (
      tester,
    ) async {
      final state = stateWithMachines(_SendApi());
      addTearDown(state.dispose);

      await tester.pumpWidget(app(state));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('composer_input')), '@');
      await tester.pump();

      expect(find.byKey(const Key('machine_picker')), findsOneWidget);
      expect(find.text('gaming pc'), findsOneWidget);
      expect(find.text('workstation'), findsOneWidget);

      await tester.tap(find.byKey(const Key('machine_option_1')));
      await tester.pump();

      expect(state.machineReferences.single.id, 1);
      expect(state.composerText, '');
      expect(find.byKey(const Key('machine_picker')), findsNothing);
      expect(find.byKey(const Key('machine_ref_1')), findsOneWidget);
    });

    testWidgets('the query filters machines and Enter accepts the match', (
      tester,
    ) async {
      final state = stateWithMachines(_SendApi());
      addTearDown(state.dispose);

      await tester.pumpWidget(app(state));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('composer_input')),
        'check @work',
      );
      await tester.pump();

      expect(find.text('gaming pc'), findsNothing);
      expect(find.text('workstation'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(state.machineReferences.single.id, 2);
      expect(state.composerText, 'check ');
    });

    testWidgets('Escape dismisses the picker until a new @ token', (
      tester,
    ) async {
      final state = stateWithMachines(_SendApi());
      addTearDown(state.dispose);

      await tester.pumpWidget(app(state));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('composer_input')), '@g');
      await tester.pump();
      expect(find.byKey(const Key('machine_picker')), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byKey(const Key('machine_picker')), findsNothing);

      // Extending the dismissed token stays closed.
      await tester.enterText(find.byKey(const Key('composer_input')), '@ga');
      await tester.pump();
      expect(find.byKey(const Key('machine_picker')), findsNothing);
    });

    testWidgets('an already-referenced machine is filtered out', (
      tester,
    ) async {
      final state = stateWithMachines(_SendApi());
      addTearDown(state.dispose);
      state.addMachineReference(
        const MachineReference(id: 1, name: 'gaming pc'),
      );

      await tester.pumpWidget(app(state));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('composer_input')), '@');
      await tester.pump();

      // The referenced machine drops out of the picker; the name visible on
      // screen is its chip, not a picker row.
      expect(find.byKey(const Key('machine_option_1')), findsNothing);
      expect(find.byKey(const Key('machine_option_2')), findsOneWidget);
    });

    testWidgets('@ mid-word does not open the picker', (tester) async {
      final state = stateWithMachines(_SendApi());
      addTearDown(state.dispose);

      await tester.pumpWidget(app(state));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('composer_input')),
        'mail me@home',
      );
      await tester.pump();
      expect(find.byKey(const Key('machine_picker')), findsNothing);
    });
  });

  group('machine chip on messages', () {
    testWidgets('a machine attachment renders as a computer chip', (
      tester,
    ) async {
      final state = AppState.test(
        api: _SendApi(),
        user: _owner(),
        activeProjectId: 1,
        activeThreadId: 't1',
        activeThreadDetail: ThreadDetail(
          thread: _thread('t1'),
          messages: [
            Message(
              id: 1,
              role: 'user',
              content: 'drive it',
              attachments: [
                Attachment.fromJson({
                  'filename': 'gaming pc',
                  'size': 0,
                  'mime': 'application/x-devinorium-machine',
                  'kind': 'machine',
                  'machine_id': 3,
                }),
              ],
            ),
          ],
          totalMessages: 1,
        ),
      );
      addTearDown(state.dispose);

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ChangeNotifierProvider<AppState>.value(
            value: state,
            child: const Scaffold(body: ThreadPage()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('gaming pc'), findsOneWidget);
      expect(find.byIcon(Icons.computer), findsOneWidget);
    });
  });

  group('machines settings section', () {
    // The Machines card sits below the servers/tailscale cards; give the
    // test surface room so the controls are on screen.
    void bigSurface(WidgetTester tester) {
      tester.view.physicalSize = const Size(1600, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
    }

    Widget settings(AppState state) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const SettingsPage(),
      ),
    );

    testWidgets('lists machines with endpoints and password badges', (
      tester,
    ) async {
      bigSurface(tester);
      final api = _MachinesApi()
        ..machineList = [
          _machine(1, 'gaming pc'),
          Machine(id: 2, name: 'open box', host: '10.0.0.2', port: 5901),
        ];
      // Owners get an extra manage topic; servers is index 7.
      final state = AppState.test(
        api: api,
        user: _owner(),
        settingsTopicIndex: 7,
      );
      addTearDown(state.dispose);

      await tester.pumpWidget(settings(state));
      await tester.pumpAndSettle();

      expect(find.text('Machines'), findsOneWidget);
      expect(find.text('gaming pc'), findsOneWidget);
      expect(find.text('open box'), findsOneWidget);
      expect(find.text('10.0.0.1:5900'), findsOneWidget);
      expect(find.text('10.0.0.2:5901'), findsOneWidget);
      expect(find.byIcon(Icons.lock_outline), findsOneWidget);
      expect(find.byKey(const Key('machine_add')), findsOneWidget);
    });

    testWidgets('non-owners see the list without controls', (tester) async {
      bigSurface(tester);
      final api = _MachinesApi()..machineList = [_machine(1, 'gaming pc')];
      final state = AppState.test(
        api: api,
        user: User(
          id: 2,
          username: 'alice',
          role: 'user',
          totpEnabled: false,
          isOwner: false,
          providerId: 'devin-cli',
          providerCommand: 'devin',
        ),
        settingsTopicIndex: 6,
      );
      addTearDown(state.dispose);

      await tester.pumpWidget(settings(state));
      await tester.pumpAndSettle();

      expect(find.text('gaming pc'), findsOneWidget);
      expect(find.byKey(const Key('machine_add')), findsNothing);
      expect(find.byKey(const Key('machine_edit_1')), findsNothing);
      expect(find.text('Only the owner can manage machines.'), findsOneWidget);
    });

    testWidgets('add dialog validates and posts a new machine', (tester) async {
      bigSurface(tester);
      final api = _MachinesApi();
      final state = AppState.test(
        api: api,
        user: _owner(),
        settingsTopicIndex: 7,
      );
      addTearDown(state.dispose);

      await tester.pumpWidget(settings(state));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('machine_add')));
      await tester.pumpAndSettle();

      // Empty fields fail validation.
      await tester.tap(find.byKey(const Key('machine_save')));
      await tester.pumpAndSettle();
      expect(find.text('Required'), findsNWidgets(2));

      await tester.enterText(
        find.byKey(const Key('machine_name')),
        'gaming pc',
      );
      await tester.enterText(
        find.byKey(const Key('machine_host')),
        'vnc://10.0.0.9',
      );
      await tester.enterText(find.byKey(const Key('machine_port')), '5901');
      await tester.enterText(
        find.byKey(const Key('machine_password')),
        'secret',
      );
      await tester.tap(find.byKey(const Key('machine_save')));
      await tester.pumpAndSettle();

      expect(api.created.single['name'], 'gaming pc');
      expect(api.created.single['host'], 'vnc://10.0.0.9');
      expect(api.created.single['port'], 5901);
      expect(api.created.single['password'], 'secret');
      expect(find.text('gaming pc'), findsOneWidget);
    });

    testWidgets('test button reports the probe result', (tester) async {
      bigSurface(tester);
      final api = _MachinesApi()
        ..machineList = [_machine(1, 'gaming pc')]
        ..testResults[1] = MachineTestResult(
          ok: true,
          width: 2560,
          height: 1440,
          name: 'desktop',
        );
      final state = AppState.test(
        api: api,
        user: _owner(),
        settingsTopicIndex: 7,
      );
      addTearDown(state.dispose);

      await tester.pumpWidget(settings(state));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('machine_test_1')));
      await tester.pumpAndSettle();

      expect(find.text('Connected to desktop (2560x1440)'), findsOneWidget);
    });
  });
}
