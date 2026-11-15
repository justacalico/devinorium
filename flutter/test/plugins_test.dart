import 'dart:convert';

import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/api/api_service.dart';
import 'package:devinorium_frontend/generated/l10n/app_localizations.dart';
import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:devinorium_frontend/views/settings_page.dart';
import 'package:flutter/material.dart';
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

class _PluginsApi extends ApiService {
  _PluginsApi() : super(client: _ThrowingClient());

  List<PluginInfo> pluginList = [];
  int pluginCalls = 0;
  String? installedSource;
  String? toggledName;
  bool? toggledEnabled;
  String? updatedName;
  String? deletedName;
  Object? pluginError;

  @override
  Future<List<PluginInfo>> plugins({String? cwd}) async {
    pluginCalls++;
    if (pluginError != null) throw pluginError!;
    return List.of(pluginList);
  }

  @override
  Future<List<String>> installPlugin(String source) async {
    installedSource = source;
    return ['newplugin'];
  }

  @override
  Future<void> setPluginEnabled(String name, bool enabled) async {
    toggledName = name;
    toggledEnabled = enabled;
  }

  @override
  Future<String> updatePlugin(String name) async {
    updatedName = name;
    return 'Already up to date.';
  }

  @override
  Future<void> deletePlugin(String name) async {
    deletedName = name;
  }

  @override
  Future<List<McpServerConfig>> mcpServers() async => [];
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

PluginInfo _plugin(
  String name, {
  bool enabled = true,
  String install = 'git',
  bool manageable = true,
  String source = 'user',
}) => PluginInfo(
  name: name,
  version: '1.2.0',
  description: 'A $name plugin',
  enabled: enabled,
  source: source,
  install: install,
  manageable: manageable,
  skills: const ['lint'],
  commands: const ['review'],
  mcpServers: const ['tools'],
  hooks: const ['SessionStart'],
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

void main() {
  group('PluginInfo model', () {
    test('parses every field', () {
      final p = PluginInfo.fromJson({
        'name': 'demo',
        'version': '0.3.0',
        'description': 'Demo plugin',
        'author': 'someone',
        'enabled': false,
        'source': 'project',
        'install': 'dir',
        'path': '/x/demo',
        'manageable': false,
        'skills': ['a'],
        'commands': ['b'],
        'mcpServers': ['c'],
        'hooks': ['UserPromptSubmit'],
      });
      expect(p.name, 'demo');
      expect(p.version, '0.3.0');
      expect(p.description, 'Demo plugin');
      expect(p.author, 'someone');
      expect(p.enabled, isFalse);
      expect(p.source, 'project');
      expect(p.install, 'dir');
      expect(p.path, '/x/demo');
      expect(p.manageable, isFalse);
      expect(p.skills, ['a']);
      expect(p.commands, ['b']);
      expect(p.mcpServers, ['c']);
      expect(p.hooks, ['UserPromptSubmit']);
    });

    test('defaults missing fields', () {
      final p = PluginInfo.fromJson({'name': 'x'});
      expect(p.enabled, isTrue);
      expect(p.source, 'user');
      expect(p.install, 'dir');
      expect(p.manageable, isFalse);
      expect(p.skills, isEmpty);
      expect(p.hooks, isEmpty);
    });
  });

  group('ApiService plugins', () {
    test('plugins gets and parses the list', () async {
      final mock = MockClient((req) async {
        expect(req.method, 'GET');
        expect(req.url.path, '/api/plugins');
        expect(req.url.queryParameters['cwd'], '/repo');
        return _json(200, {
          'plugins': [
            {'name': 'a'},
            {'name': 'b', 'source': 'project'},
          ],
        });
      });
      final service = ApiService(client: ApiClient.withClient(mock));
      final plugins = await service.plugins(cwd: '/repo');
      expect(plugins.map((p) => p.name), ['a', 'b']);
      expect(plugins[1].source, 'project');
    });

    test('plugins omits the cwd param when empty', () async {
      final mock = MockClient((req) async {
        expect(req.url.query, isEmpty);
        return _json(200, {'plugins': []});
      });
      final service = ApiService(client: ApiClient.withClient(mock));
      await service.plugins();
    });

    test('installPlugin posts the source', () async {
      final mock = MockClient((req) async {
        expect(req.method, 'POST');
        expect(req.url.path, '/api/plugins/install');
        expect(jsonDecode(req.body)['source'], 'https://git/x');
        return _json(200, {'installed': ['one', 'two']});
      });
      final service = ApiService(client: ApiClient.withClient(mock));
      expect(
        await service.installPlugin('https://git/x'),
        ['one', 'two'],
      );
    });

    test('setPluginEnabled puts the flag', () async {
      final mock = MockClient((req) async {
        expect(req.method, 'PUT');
        expect(req.url.path, '/api/plugins/demo/enabled');
        expect(jsonDecode(req.body)['enabled'], isFalse);
        return _json(200, {'enabled': false});
      });
      final service = ApiService(client: ApiClient.withClient(mock));
      await service.setPluginEnabled('demo', false);
    });

    test('updatePlugin posts and returns output', () async {
      final mock = MockClient((req) async {
        expect(req.method, 'POST');
        expect(req.url.path, '/api/plugins/demo/update');
        return _json(200, {'output': 'ok'});
      });
      final service = ApiService(client: ApiClient.withClient(mock));
      expect(await service.updatePlugin('demo'), 'ok');
    });

    test('deletePlugin deletes by name', () async {
      final mock = MockClient((req) async {
        expect(req.method, 'DELETE');
        expect(req.url.path, '/api/plugins/demo');
        return _json(200, {'ok': true});
      });
      final service = ApiService(client: ApiClient.withClient(mock));
      await service.deletePlugin('demo');
    });
  });

  group('plugins store', () {
    testWidgets('loadPlugins skips non-owners', (tester) async {
      final api = _PluginsApi()..pluginList = [_plugin('a')];
      final state = AppState.test(api: api, user: _member());
      addTearDown(state.dispose);
      await state.loadPlugins();
      expect(api.pluginCalls, 0);
      expect(state.plugins, isEmpty);
    });

    testWidgets('loadPlugins keeps the list on failure', (tester) async {
      final api = _PluginsApi()..pluginList = [_plugin('a')];
      final state = AppState.test(api: api, user: _owner());
      addTearDown(state.dispose);
      await state.loadPlugins();
      expect(state.plugins.single.name, 'a');
      api.pluginError = ApiException('down', 500);
      await state.loadPlugins();
      expect(state.plugins.single.name, 'a');
    });

    testWidgets('setPluginEnabled patches the flag locally', (tester) async {
      final api = _PluginsApi()
        ..pluginList = [_plugin('a'), _plugin('b', enabled: false)];
      final state = AppState.test(api: api, user: _owner());
      addTearDown(state.dispose);
      await state.loadPlugins();
      final err = await state.setPluginEnabled('b', true);
      expect(err, isNull);
      expect(api.toggledName, 'b');
      expect(api.toggledEnabled, isTrue);
      expect(state.plugins[1].enabled, isTrue);
      expect(state.plugins[0].enabled, isTrue);
    });

    testWidgets('deletePlugin drops the entry', (tester) async {
      final api = _PluginsApi()..pluginList = [_plugin('a'), _plugin('b')];
      final state = AppState.test(api: api, user: _owner());
      addTearDown(state.dispose);
      await state.loadPlugins();
      final err = await state.deletePlugin('a');
      expect(err, isNull);
      expect(api.deletedName, 'a');
      expect(state.plugins.map((p) => p.name), ['b']);
    });
  });

  group('plugins settings section', () {
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
    // manage, about, servers, usage, audit, mcp, webAccess, plugins.
    const pluginsTopicIndex = 12;

    testWidgets('lists plugins with contents summary', (tester) async {
      bigSurface(tester);
      final api = _PluginsApi()..pluginList = [_plugin('demo')];
      final state = AppState.test(
        api: api,
        user: _owner(),
        settingsTopicIndex: pluginsTopicIndex,
      );
      addTearDown(state.dispose);

      await tester.pumpWidget(settings(state));
      await tester.pumpAndSettle();

      expect(find.text('Plugins'), findsWidgets);
      expect(find.text('demo'), findsOneWidget);
      expect(find.text('1.2.0'), findsOneWidget);
      expect(find.textContaining('A demo plugin'), findsOneWidget);
      expect(find.textContaining('1 skill'), findsOneWidget);
      expect(find.byKey(const Key('plugin_demo')), findsOneWidget);
    });

    testWidgets('the switch toggles the plugin', (tester) async {
      bigSurface(tester);
      final api = _PluginsApi()..pluginList = [_plugin('demo')];
      final state = AppState.test(
        api: api,
        user: _owner(),
        settingsTopicIndex: pluginsTopicIndex,
      );
      addTearDown(state.dispose);

      await tester.pumpWidget(settings(state));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();

      expect(api.toggledName, 'demo');
      expect(api.toggledEnabled, isFalse);
      expect(state.plugins.single.enabled, isFalse);
    });

    testWidgets('install submits the source field', (tester) async {
      bigSurface(tester);
      final api = _PluginsApi();
      final state = AppState.test(
        api: api,
        user: _owner(),
        settingsTopicIndex: pluginsTopicIndex,
      );
      addTearDown(state.dispose);

      await tester.pumpWidget(settings(state));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byType(TextField).first,
        'https://git.example.com/plug',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Install'));
      await tester.pumpAndSettle();

      expect(api.installedSource, 'https://git.example.com/plug');
    });

    testWidgets('uninstall asks then deletes', (tester) async {
      bigSurface(tester);
      final api = _PluginsApi()..pluginList = [_plugin('demo')];
      final state = AppState.test(
        api: api,
        user: _owner(),
        settingsTopicIndex: pluginsTopicIndex,
      );
      addTearDown(state.dispose);

      await tester.pumpWidget(settings(state));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();
      expect(find.textContaining('Uninstall'), findsWidgets);

      await tester.tap(find.widgetWithText(FilledButton, 'Uninstall'));
      await tester.pumpAndSettle();
      expect(api.deletedName, 'demo');
      expect(state.plugins, isEmpty);
    });

    testWidgets('update hits the git plugin route', (tester) async {
      bigSurface(tester);
      final api = _PluginsApi()
        ..pluginList = [_plugin('demo', install: 'git')];
      final state = AppState.test(
        api: api,
        user: _owner(),
        settingsTopicIndex: pluginsTopicIndex,
      );
      addTearDown(state.dispose);

      await tester.pumpWidget(settings(state));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.refresh_outlined));
      await tester.pumpAndSettle();
      expect(api.updatedName, 'demo');
    });

    testWidgets('non-owner has no plugins topic', (tester) async {
      bigSurface(tester);
      final api = _PluginsApi()..pluginList = [_plugin('demo')];
      final state = AppState.test(api: api, user: _member());
      addTearDown(state.dispose);

      await tester.pumpWidget(settings(state));
      await tester.pumpAndSettle();

      expect(find.text('Plugins'), findsNothing);
      expect(find.byKey(const Key('plugin_demo')), findsNothing);
    });
  });
}
