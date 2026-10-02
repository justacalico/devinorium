import 'dart:async';
import 'dart:convert';

import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/api/api_service.dart';
import 'package:devinorium_frontend/generated/l10n/app_localizations.dart';
import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:devinorium_frontend/views/settings_page.dart';
import 'package:devinorium_frontend/views/thread_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

class _ThrowingClient implements BaseApiClient {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

http.Response _json(int status, Object body) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

/// ApiService stub for the settings endpoints the page loads on open plus
/// the MCP + skills routes under test.
class _McpApi extends ApiService {
  _McpApi() : super(client: _ThrowingClient());

  List<McpServerConfig> serverList = [];
  List<List<McpServerConfig>> saved = [];
  Object? saveError;
  List<Skill> skillList = [];
  int mcpCalls = 0;
  int skillsCalls = 0;

  @override
  Future<List<McpServerConfig>> mcpServers() async {
    mcpCalls++;
    return List.of(serverList);
  }

  @override
  Future<List<McpServerConfig>> saveMcpServers(
    List<McpServerConfig> servers,
  ) async {
    if (saveError != null) throw saveError!;
    saved.add(List.of(servers));
    serverList = List.of(servers);
    return List.of(servers);
  }

  @override
  Future<List<Skill>> skills(String threadId) async {
    skillsCalls++;
    return List.of(skillList);
  }

  McpbInfo inspectInfo = const McpbInfo(name: 'demo');
  Object? inspectError;
  String? inspectedFile;
  String? installedFile;
  Map<String, dynamic>? installedConfig;

  @override
  Future<McpbInfo> inspectMcpb({
    required String filename,
    required Uint8List bytes,
  }) async {
    inspectedFile = filename;
    if (inspectError != null) throw inspectError!;
    return inspectInfo;
  }

  @override
  Future<List<McpServerConfig>> installMcpb({
    required String filename,
    required Uint8List bytes,
    required Map<String, dynamic> config,
  }) async {
    installedFile = filename;
    installedConfig = config;
    serverList = [...serverList, _stdio('demo', command: 'node')];
    return List.of(serverList);
  }

  // Settings-page loaders.
  @override
  Future<List<GitConnection>> listGitConnections() async => [];
  @override
  Future<List<Machine>> machines() async => [];
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
  @override
  Future<FederationNodesResponse> federationNodes() async =>
      FederationNodesResponse(nodes: const []);
}

class _SendApi extends ApiService {
  _SendApi() : super(client: _ThrowingClient());

  String? sentPrompt;

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
    return Stream.fromIterable([
      SseEvent(
        'user_message',
        '{"id": 2, "role": "user", "content": "x"}',
        id: '1',
      ),
      SseEvent(
        'done',
        '{"id": 3, "role": "assistant", "content": "ok"}',
        id: '2',
      ),
    ]);
  }

  @override
  Future<List<Skill>> skills(String threadId) async => [];
}

McpServerConfig _stdio(
  String name, {
  bool enabled = true,
  String command = 'npx',
}) => McpServerConfig(
  name: name,
  enabled: enabled,
  transport: 'stdio',
  command: command,
  args: const ['-y', 'pkg'],
  env: const {'TOKEN': 'x'},
);

McpServerConfig _remote(String name) => McpServerConfig(
  name: name,
  transport: 'http',
  url: 'https://mcp.example.com/mcp',
  headers: const {'Authorization': 'Bearer t'},
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

User _member() => User(
  id: 2,
  username: 'alice',
  role: 'user',
  totpEnabled: false,
  isOwner: false,
  providerId: 'devin-cli',
  providerCommand: 'devin',
);

Thread _thread(String id) => Thread(
  id: id,
  title: 'Current',
  projectId: 1,
  model: 'm1',
  permissionMode: 'normal',
  createdAt: '',
  updatedAt: '',
);

void main() {
  group('McpServerConfig model', () {
    test('parses a stdio entry', () {
      final s = McpServerConfig.fromJson({
        'name': 'github',
        'enabled': true,
        'transport': 'stdio',
        'command': 'npx',
        'args': ['-y', '@gh/mcp'],
        'env': {'TOKEN': 'abc'},
      });
      expect(s.name, 'github');
      expect(s.enabled, isTrue);
      expect(s.transport, 'stdio');
      expect(s.command, 'npx');
      expect(s.args, ['-y', '@gh/mcp']);
      expect(s.env, {'TOKEN': 'abc'});
      expect(s.isRemote, isFalse);
      expect(s.endpoint, 'npx -y @gh/mcp');
    });

    test('parses a remote entry and formats the endpoint', () {
      final s = McpServerConfig.fromJson({
        'name': 'notion',
        'transport': 'http',
        'url': 'https://mcp.notion.com/mcp',
        'headers': {'Authorization': 'Bearer t'},
      });
      expect(s.isRemote, isTrue);
      expect(s.endpoint, 'https://mcp.notion.com/mcp');
      expect(s.headers['Authorization'], 'Bearer t');
    });

    test('defaults enabled and transport when absent', () {
      final s = McpServerConfig.fromJson({'name': 'x', 'command': 'run'});
      expect(s.enabled, isTrue);
      expect(s.transport, 'stdio');
    });

    test('round trips through json without empty fields', () {
      final s = _stdio('a');
      final j = s.toJson();
      expect(j.containsKey('url'), isFalse);
      expect(j.containsKey('headers'), isFalse);
      final back = McpServerConfig.fromJson(j);
      expect(back.name, s.name);
      expect(back.args, s.args);
      expect(back.env, s.env);
    });
  });

  group('Skill model', () {
    test('parses name, description, hint and source', () {
      final s = Skill.fromJson({
        'name': 'review',
        'description': 'Review code',
        'argument_hint': '[file]',
        'source': 'project',
      });
      expect(s.name, 'review');
      expect(s.description, 'Review code');
      expect(s.argumentHint, '[file]');
      expect(s.source, 'project');
    });

    test('defaults missing fields', () {
      final s = Skill.fromJson({'name': 'x'});
      expect(s.description, '');
      expect(s.argumentHint, '');
      expect(s.source, 'project');
    });
  });

  group('ApiService', () {
    test('mcpServers gets and parses the list', () async {
      final mock = MockClient((req) async {
        expect(req.method, 'GET');
        expect(req.url.path, '/api/settings/mcp-servers');
        return _json(200, {
          'servers': [
            {'name': 'a', 'command': 'npx'},
            {'name': 'b', 'transport': 'http', 'url': 'https://x/mcp'},
          ],
        });
      });
      final service = ApiService(client: ApiClient.withClient(mock));
      final servers = await service.mcpServers();
      expect(servers.length, 2);
      expect(servers[0].name, 'a');
      expect(servers[1].url, 'https://x/mcp');
    });

    test('saveMcpServers puts the whole list', () async {
      final mock = MockClient((req) async {
        expect(req.method, 'PUT');
        expect(req.url.path, '/api/settings/mcp-servers');
        final body = jsonDecode(req.body);
        expect(body['servers'], hasLength(1));
        expect(body['servers'][0]['name'], 'a');
        return _json(200, body);
      });
      final service = ApiService(client: ApiClient.withClient(mock));
      final servers = await service.saveMcpServers([_stdio('a')]);
      expect(servers.single.name, 'a');
    });

    test('skills gets and parses the list', () async {
      final mock = MockClient((req) async {
        expect(req.method, 'GET');
        expect(req.url.path, '/api/threads/t1/skills');
        return _json(200, {
          'skills': [
            {'name': 'review', 'description': 'Review', 'source': 'project'},
          ],
        });
      });
      final service = ApiService(client: ApiClient.withClient(mock));
      final skills = await service.skills('t1');
      expect(skills.single.name, 'review');
    });
  });

  group('McpStore', () {
    test('loadMcpServers is a no-op for non-owners', () async {
      final api = _McpApi()..serverList = [_stdio('a')];
      final state = AppState.test(api: api, user: _member());
      addTearDown(state.dispose);
      await state.loadMcpServers();
      expect(api.mcpCalls, 0);
      expect(state.mcpServers, isEmpty);
    });

    test('loadMcpServers fills the list for the owner', () async {
      final api = _McpApi()..serverList = [_stdio('a'), _remote('b')];
      final state = AppState.test(api: api, user: _owner());
      addTearDown(state.dispose);
      await state.loadMcpServers();
      expect(state.mcpServers.map((s) => s.name), ['a', 'b']);
    });

    test('saveMcpServers replaces the list and reports errors', () async {
      final api = _McpApi()..serverList = [_stdio('a')];
      final state = AppState.test(api: api, user: _owner());
      addTearDown(state.dispose);
      await state.loadMcpServers();

      expect(await state.saveMcpServers([_stdio('a'), _remote('b')]), isNull);
      expect(state.mcpServers.map((s) => s.name), ['a', 'b']);

      api.saveError = ApiException('bad list', 400);
      expect(await state.saveMcpServers([_stdio('a')]), 'bad list');
      // A failed write leaves the stored list untouched.
      expect(state.mcpServers.map((s) => s.name), ['a', 'b']);
    });

    test('skills only reports the active thread’s list', () async {
      final api = _McpApi()
        ..skillList = [const Skill(name: 'review', description: 'Review code')];
      final state = AppState.test(api: api, user: _owner());
      addTearDown(state.dispose);

      // No active thread: nothing loads and nothing is reported.
      await state.loadSkills();
      expect(api.skillsCalls, 0);
      expect(state.skills, isEmpty);
    });

    test('loadSkills fetches once for a populated list', () async {
      final api = _McpApi()..skillList = [const Skill(name: 'review')];
      final state = AppState.test(
        api: api,
        user: _owner(),
        activeProjectId: 1,
        activeThreadId: 't1',
        activeThreadDetail: ThreadDetail(
          thread: _thread('t1'),
          messages: const [],
        ),
      );
      addTearDown(state.dispose);

      await state.loadSkills();
      await state.loadSkills();
      expect(api.skillsCalls, 1);
      expect(state.skills.single.name, 'review');
    });

    test('an empty result refetches on the next open', () async {
      final api = _McpApi();
      final state = AppState.test(
        api: api,
        user: _owner(),
        activeProjectId: 1,
        activeThreadId: 't1',
        activeThreadDetail: ThreadDetail(
          thread: _thread('t1'),
          messages: const [],
        ),
      );
      addTearDown(state.dispose);

      await state.loadSkills();
      api.skillList = [const Skill(name: 'new')];
      await state.loadSkills();
      expect(api.skillsCalls, 2);
      expect(state.skills.single.name, 'new');
    });
  });

  group('mcp settings section', () {
    // The MCP topic is owner-only and last; the surface needs room for the
    // whole settings page.
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

    // Owner order: account, providers, personalization, git, directories,
    // manage, about, servers, usage, audit, mcp.
    const mcpTopicIndex = 10;

    testWidgets('lists servers with endpoints and an enable switch', (
      tester,
    ) async {
      bigSurface(tester);
      final api = _McpApi()..serverList = [_stdio('github'), _remote('notion')];
      final state = AppState.test(
        api: api,
        user: _owner(),
        settingsTopicIndex: mcpTopicIndex,
      );
      addTearDown(state.dispose);

      await tester.pumpWidget(settings(state));
      await tester.pumpAndSettle();

      expect(find.text('MCP servers'), findsWidgets); // topic + section
      expect(find.text('github'), findsOneWidget);
      expect(find.text('notion'), findsOneWidget);
      expect(find.text('npx -y pkg'), findsOneWidget);
      expect(find.text('https://mcp.example.com/mcp'), findsOneWidget);
      expect(find.byKey(const Key('mcp_add')), findsOneWidget);
      expect(find.byKey(const Key('mcp_enable_github')), findsOneWidget);
    });

    testWidgets('the enable switch saves a flipped flag', (tester) async {
      bigSurface(tester);
      final api = _McpApi()..serverList = [_stdio('github')];
      final state = AppState.test(
        api: api,
        user: _owner(),
        settingsTopicIndex: mcpTopicIndex,
      );
      addTearDown(state.dispose);

      await tester.pumpWidget(settings(state));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('mcp_enable_github')));
      await tester.pumpAndSettle();

      expect(api.saved.single.single.enabled, isFalse);
      expect(state.mcpServers.single.enabled, isFalse);
    });

    testWidgets('deleting a server drops it from the saved list', (
      tester,
    ) async {
      bigSurface(tester);
      final api = _McpApi()..serverList = [_stdio('github'), _remote('notion')];
      final state = AppState.test(
        api: api,
        user: _owner(),
        settingsTopicIndex: mcpTopicIndex,
      );
      addTearDown(state.dispose);

      await tester.pumpWidget(settings(state));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('mcp_delete_github')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(api.saved.single.map((s) => s.name), ['notion']);
    });

    testWidgets('the add dialog writes a stdio server', (tester) async {
      bigSurface(tester);
      final api = _McpApi();
      final state = AppState.test(
        api: api,
        user: _owner(),
        settingsTopicIndex: mcpTopicIndex,
      );
      addTearDown(state.dispose);

      await tester.pumpWidget(settings(state));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('mcp_add')));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('mcp_name')), 'tools');
      await tester.enterText(find.byKey(const Key('mcp_command')), 'uvx');
      await tester.enterText(
        find.byKey(const Key('mcp_args')),
        'run\ntools-mcp',
      );
      await tester.enterText(
        find.byKey(const Key('mcp_env')),
        'KEY=val\nOTHER=1',
      );
      await tester.tap(find.byKey(const Key('mcp_save')));
      await tester.pumpAndSettle();

      final saved = api.saved.single.single;
      expect(saved.name, 'tools');
      expect(saved.transport, 'stdio');
      expect(saved.command, 'uvx');
      expect(saved.args, ['run', 'tools-mcp']);
      expect(saved.env, {'KEY': 'val', 'OTHER': '1'});
    });

    testWidgets('the remote transport swaps the field set', (tester) async {
      bigSurface(tester);
      final api = _McpApi();
      final state = AppState.test(
        api: api,
        user: _owner(),
        settingsTopicIndex: mcpTopicIndex,
      );
      addTearDown(state.dispose);

      await tester.pumpWidget(settings(state));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('mcp_add')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('HTTP'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('mcp_url')), findsOneWidget);
      expect(find.byKey(const Key('mcp_command')), findsNothing);

      await tester.enterText(find.byKey(const Key('mcp_name')), 'remote');
      await tester.enterText(
        find.byKey(const Key('mcp_url')),
        'https://mcp.example.com/mcp',
      );
      await tester.enterText(
        find.byKey(const Key('mcp_headers')),
        'Authorization=Bearer t',
      );
      await tester.tap(find.byKey(const Key('mcp_save')));
      await tester.pumpAndSettle();

      final saved = api.saved.single.single;
      expect(saved.transport, 'http');
      expect(saved.url, 'https://mcp.example.com/mcp');
      expect(saved.headers['Authorization'], 'Bearer t');
      // Stdio fields stay empty so the JSON has no stray keys.
      expect(saved.toJson().containsKey('command'), isFalse);
    });

    testWidgets('editing a server replaces it by name', (tester) async {
      bigSurface(tester);
      final api = _McpApi()..serverList = [_stdio('github')];
      final state = AppState.test(
        api: api,
        user: _owner(),
        settingsTopicIndex: mcpTopicIndex,
      );
      addTearDown(state.dispose);

      await tester.pumpWidget(settings(state));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('mcp_edit_github')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('mcp_command')), 'uvx');
      await tester.tap(find.byKey(const Key('mcp_save')));
      await tester.pumpAndSettle();

      expect(api.saved.single.single.command, 'uvx');
      expect(api.saved.single.single.name, 'github');
    });

    testWidgets('non-owners do not get the mcp topic', (tester) async {
      bigSurface(tester);
      final api = _McpApi()..serverList = [_stdio('github')];
      final state = AppState.test(api: api, user: _member());
      addTearDown(state.dispose);

      await tester.pumpWidget(settings(state));
      await tester.pumpAndSettle();

      expect(find.text('MCP servers'), findsNothing);
      expect(api.mcpCalls, 0);
    });
  });

  group('composer / picker', () {
    AppState stateWithSkills(ApiService api) => AppState.test(
      api: api,
      user: _owner(),
      skills: const [
        Skill(name: 'review', description: 'Review code', source: 'project'),
        Skill(
          name: 'find',
          description: 'Find code',
          source: 'user',
          argumentHint: '<query>',
        ),
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

    testWidgets('typing / lists skills and tapping completes the command', (
      tester,
    ) async {
      final state = stateWithSkills(_SendApi());
      addTearDown(state.dispose);

      await tester.pumpWidget(app(state));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('composer_input')), '/');
      await tester.pump();

      expect(find.byKey(const Key('skill_picker')), findsOneWidget);
      expect(find.text('/review'), findsOneWidget);
      expect(find.text('/find'), findsOneWidget);

      await tester.tap(find.byKey(const Key('skill_option_review')));
      await tester.pump();

      expect(state.composerText, '/review ');
      expect(find.byKey(const Key('skill_picker')), findsNothing);
    });

    testWidgets('the query filters and Enter accepts the match', (
      tester,
    ) async {
      final state = stateWithSkills(_SendApi());
      addTearDown(state.dispose);

      await tester.pumpWidget(app(state));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('composer_input')), '/fi');
      await tester.pump();

      expect(find.text('/review'), findsNothing);
      expect(find.text('/find'), findsOneWidget);
      expect(find.text('<query>'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(state.composerText, '/find ');
    });

    testWidgets('a picked command with args sends verbatim', (tester) async {
      final api = _SendApi();
      final state = stateWithSkills(api);
      addTearDown(state.dispose);

      await tester.pumpWidget(app(state));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('composer_input')), '/rev');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      await tester.enterText(
        find.byKey(const Key('composer_input')),
        '/review src/main.rs',
      );
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      // The literal slash command reaches the backend; expansion happens
      // there so devin-cli resolves it natively.
      expect(api.sentPrompt, '/review src/main.rs');
    });

    testWidgets('Escape dismisses until the token is retyped', (tester) async {
      final state = stateWithSkills(_SendApi());
      addTearDown(state.dispose);

      await tester.pumpWidget(app(state));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('composer_input')), '/r');
      await tester.pump();
      expect(find.byKey(const Key('skill_picker')), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byKey(const Key('skill_picker')), findsNothing);

      await tester.enterText(find.byKey(const Key('composer_input')), '/re');
      await tester.pump();
      expect(find.byKey(const Key('skill_picker')), findsNothing);
    });

    testWidgets('an absolute path does not open the picker', (tester) async {
      final state = stateWithSkills(_SendApi());
      addTearDown(state.dispose);

      await tester.pumpWidget(app(state));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('composer_input')),
        '/usr/bin/x',
      );
      await tester.pump();
      expect(find.byKey(const Key('skill_picker')), findsNothing);
    });

    testWidgets('a mid-text slash does not open the picker', (tester) async {
      final state = stateWithSkills(_SendApi());
      addTearDown(state.dispose);

      await tester.pumpWidget(app(state));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('composer_input')),
        'fix a/b please',
      );
      await tester.pump();
      expect(find.byKey(const Key('skill_picker')), findsNothing);
    });

    testWidgets('a thread without skills shows the empty hint', (tester) async {
      final state = AppState.test(
        api: _SendApi(),
        user: _owner(),
        activeProjectId: 1,
        activeThreadId: 't1',
        activeThreadDetail: ThreadDetail(
          thread: _thread('t1'),
          messages: const [],
        ),
      );
      addTearDown(state.dispose);

      await tester.pumpWidget(app(state));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('composer_input')), '/');
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('skill_picker')), findsOneWidget);
      expect(find.text('No skills found for this thread.'), findsOneWidget);
    });
  });
  group('mcpb bundles', () {
    final bundleBytes = Uint8List.fromList(utf8.encode('fake-mcpb'));
    const info = McpbInfo(
      name: 'demo',
      displayName: 'Demo Bundle',
      version: '1.0',
      description: 'A demo bundle',
      author: 'T',
      serverType: 'node',
      warnings: ['heads up'],
      userConfig: [
        McpbUserConfig(
          key: 'token',
          type: 'string',
          title: 'Token',
          description: 'Your API token',
          required: true,
          sensitive: true,
        ),
        McpbUserConfig(key: 'verbose', type: 'boolean', title: 'Verbose'),
      ],
    );

    group('McpbInfo model', () {
      test('parses inspect responses', () {
        final m = McpbInfo.fromJson({
          'name': 'demo',
          'displayName': 'Demo Bundle',
          'version': '1.2.0',
          'description': 'd',
          'author': 'A',
          'serverType': 'python',
          'warnings': ['w1'],
          'userConfig': [
            {
              'key': 'api_key',
              'type': 'string',
              'title': 'API Key',
              'required': true,
              'sensitive': true,
            },
            {
              'key': 'dirs',
              'type': 'directory',
              'multiple': true,
              'default': ['a'],
            },
          ],
        });
        expect(m.name, 'demo');
        expect(m.serverType, 'python');
        expect(m.warnings, ['w1']);
        expect(m.userConfig[0].key, 'api_key');
        expect(m.userConfig[0].required, isTrue);
        expect(m.userConfig[1].multiple, isTrue);
        expect(m.userConfig[1].defaultValue, ['a']);
      });
    });

    group('ApiService', () {
      test('inspectMcpb posts the bundle as multipart', () async {
        final mock = MockClient((req) async {
          expect(req.method, 'POST');
          expect(req.url.path, '/api/settings/mcp-servers/mcpb/inspect');
          expect(
            req.headers['content-type'],
            startsWith('multipart/form-data'),
          );
          return _json(200, {
            'name': 'demo',
            'serverType': 'node',
            'userConfig': [
              {'key': 'token', 'required': true},
            ],
          });
        });
        final service = ApiService(client: ApiClient.withClient(mock));
        final m = await service.inspectMcpb(
          filename: 'demo.mcpb',
          bytes: bundleBytes,
        );
        expect(m.name, 'demo');
        expect(m.userConfig.single.key, 'token');
      });

      test('installMcpb sends config and returns the new list', () async {
        String? sentBody;
        final mock = MockClient((req) async {
          expect(req.method, 'POST');
          expect(req.url.path, '/api/settings/mcp-servers/mcpb/install');
          expect(
            req.headers['content-type'],
            startsWith('multipart/form-data'),
          );
          sentBody = req.body;
          return _json(200, {
            'servers': [
              {'name': 'demo', 'command': 'node'},
            ],
          });
        });
        final service = ApiService(client: ApiClient.withClient(mock));
        final servers = await service.installMcpb(
          filename: 'demo.mcpb',
          bytes: bundleBytes,
          config: {'token': 'abc'},
        );
        expect(sentBody, contains('name="config"'));
        expect(sentBody, contains('"token":"abc"'));
        expect(sentBody, contains('demo.mcpb'));
        expect(servers.single.name, 'demo');
      });
    });

    group('McpStore', () {
      test('installMcpb replaces the stored list', () async {
        final api = _McpApi()..serverList = [_stdio('old')];
        final state = AppState.test(api: api, user: _owner());
        addTearDown(state.dispose);
        await state.loadMcpServers();

        final error = await state.installMcpb('demo.mcpb', bundleBytes, {
          'token': 'abc',
        });
        expect(error, isNull);
        expect(api.installedFile, 'demo.mcpb');
        expect(api.installedConfig, {'token': 'abc'});
        expect(state.mcpServers.map((s) => s.name), ['old', 'demo']);
      });
    });

    group('mcp settings section', () {
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

      const mcpTopicIndex = 10;

      testWidgets('install flow inspects then installs the bundle', (
        tester,
      ) async {
        bigSurface(tester);
        final api = _McpApi()..inspectInfo = info;
        final state = AppState.test(
          api: api,
          user: _owner(),
          settingsTopicIndex: mcpTopicIndex,
        );
        addTearDown(state.dispose);
        final previous = mcpbBundlePicker;
        mcpbBundlePicker = () async => (name: 'demo.mcpb', bytes: bundleBytes);
        addTearDown(() => mcpbBundlePicker = previous);

        await tester.pumpWidget(settings(state));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('mcp_install_bundle')));
        await tester.pumpAndSettle();

        // The dialog shows the inspected manifest and its config fields.
        expect(api.inspectedFile, 'demo.mcpb');
        expect(find.text('Demo Bundle'), findsOneWidget);
        expect(find.text('heads up'), findsOneWidget);
        expect(find.byKey(const Key('mcpb_cfg_token')), findsOneWidget);
        expect(find.byKey(const Key('mcpb_cfg_verbose')), findsOneWidget);

        // Required fields block the install.
        await tester.tap(find.byKey(const Key('mcpb_install')));
        await tester.pumpAndSettle();
        expect(api.installedFile, isNull);

        await tester.enterText(
          find.byKey(const Key('mcpb_cfg_token')),
          'sekret',
        );
        await tester.tap(find.byKey(const Key('mcpb_cfg_verbose')));
        await tester.tap(find.byKey(const Key('mcpb_install')));
        await tester.pumpAndSettle();

        expect(api.installedFile, 'demo.mcpb');
        expect(api.installedConfig, {'token': 'sekret', 'verbose': true});
        expect(state.mcpServers.single.name, 'demo');
      });

      testWidgets('an inspect failure surfaces the error', (tester) async {
        bigSurface(tester);
        final api = _McpApi()..inspectError = ApiException('bad bundle', 400);
        final state = AppState.test(
          api: api,
          user: _owner(),
          settingsTopicIndex: mcpTopicIndex,
        );
        addTearDown(state.dispose);
        final previous = mcpbBundlePicker;
        mcpbBundlePicker = () async => (name: 'demo.mcpb', bytes: bundleBytes);
        addTearDown(() => mcpbBundlePicker = previous);

        await tester.pumpWidget(settings(state));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('mcp_install_bundle')));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('mcpb_install')), findsNothing);
        expect(state.globalError, contains('bad bundle'));
      });
    });
  });
}
