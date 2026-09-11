import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/api/api_service.dart';
import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/servers/multi_server_state.dart';
import 'package:devinorium_frontend/servers/server_profile.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:devinorium_frontend/views/sidebar.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeAppState extends AppState {
  String? switchedTo;

  _FakeAppState({required MultiServerState multi, super.user})
      : super.test(multiServerState: multi, projects: const []);

  @override
  Future<void> switchServer(String serverId) async {
    switchedTo = serverId;
    await multiServerState.setActiveServer(serverId);
  }
}

MultiServerState _twoServerState() {
  final multi = MultiServerState();
  final work = ServerProfile(
    id: 'work',
    label: 'work',
    baseUrl: 'http://work:7878',
    token: 't1',
    username: 'owner',
    createdAt: DateTime(2024, 1, 1).toUtc(),
  );
  final home = ServerProfile(
    id: 'home',
    label: 'home',
    baseUrl: 'http://home:7878',
    token: 't2',
    username: 'owner',
    createdAt: DateTime(2024, 1, 2).toUtc(),
    isPrimary: true,
  );
  final client = ApiClient.withClient(
    MockClient((_) async => http.Response('{}', 200)),
  );
  multi.addTestConnection(work, ApiService(client: client));
  multi.addTestConnection(home, ApiService(client: client));
  return multi;
}

MultiServerState _oneServerState() {
  final multi = MultiServerState();
  final home = ServerProfile(
    id: 'home',
    label: 'home',
    baseUrl: 'http://home:7878',
    token: 't2',
    username: 'owner',
    createdAt: DateTime(2024, 1, 2).toUtc(),
    isPrimary: true,
  );
  final client = ApiClient.withClient(
    MockClient((_) async => http.Response('{}', 200)),
  );
  multi.addTestConnection(home, ApiService(client: client));
  return multi;
}

Widget _buildWithState(AppState state) => MaterialApp(
      home: ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const Scaffold(
          body: Sidebar(),
        ),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    PackageInfo.setMockInitialValues(
      appName: 'Devinorium',
      packageName: 'devinorium_frontend',
      version: '0.21.0',
      buildNumber: '25',
      buildSignature: '',
    );
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('Server switcher is hidden with only one server', (
    tester,
  ) async {
    final state = _FakeAppState(
      multi: _oneServerState(),
      user: User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        isOwner: true,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
    );
    addTearDown(state.dispose);

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.cloud_outlined), findsNothing);
    expect(find.byIcon(Icons.expand_more), findsNothing);
  });

  testWidgets('Server switcher shows active server when multiple are configured', (
    tester,
  ) async {
    final state = _FakeAppState(
      multi: _twoServerState(),
      user: User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        isOwner: true,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
    );
    addTearDown(state.dispose);

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    expect(find.text('home'), findsOneWidget);
    expect(find.byIcon(Icons.cloud_outlined), findsOneWidget);
    expect(find.byIcon(Icons.expand_more), findsOneWidget);
  });

  testWidgets('Server switcher menu lists all servers and switches active', (
    tester,
  ) async {
    final state = _FakeAppState(
      multi: _twoServerState(),
      user: User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        isOwner: true,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
    );
    addTearDown(state.dispose);

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    await tester.tap(find.text('home'));
    await tester.pumpAndSettle();

    expect(find.text('home'), findsWidgets);
    expect(find.text('work'), findsOneWidget);
    expect(find.text('Manage servers'), findsOneWidget);

    await tester.tap(find.text('work'));
    await tester.pumpAndSettle();

    expect(state.switchedTo, 'work');
    expect(state.activeServerId, 'work');
    expect(find.text('work'), findsOneWidget);
  });

  testWidgets('Bundled local server shows This device with a computer icon', (
    tester,
  ) async {
    final multi = MultiServerState();
    final local = ServerProfile(
      id: MultiServerState.localProfileId,
      label: 'local',
      baseUrl: 'http://127.0.0.1:41234',
      token: 't',
      username: 'local',
      createdAt: DateTime(2024, 1, 2).toUtc(),
      isPrimary: true,
      isLocal: true,
    );
    final remote = ServerProfile(
      id: 'remote',
      label: 'remote',
      baseUrl: 'http://remote:7878',
      token: 't2',
      username: 'owner',
      createdAt: DateTime(2024, 1, 1).toUtc(),
    );
    final client = ApiClient.withClient(
      MockClient((_) async => http.Response('{}', 200)),
    );
    multi.addTestConnection(remote, ApiService(client: client));
    multi.addTestConnection(local, ApiService(client: client));

    final state = _FakeAppState(
      multi: multi,
      user: User(
        id: 1,
        username: 'local',
        role: 'user',
        totpEnabled: false,
        isOwner: true,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
    );
    addTearDown(state.dispose);

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    expect(find.text('This device'), findsOneWidget);
    expect(find.byIcon(Icons.computer_outlined), findsOneWidget);
    expect(find.byIcon(Icons.cloud_outlined), findsNothing);

    // The menu still lists the remote server for switching.
    await tester.tap(find.text('This device'));
    await tester.pumpAndSettle();
    expect(find.text('remote'), findsOneWidget);
  });

  testWidgets('Manage servers menu item opens server settings', (
    tester,
  ) async {
    final state = _FakeAppState(
      multi: _twoServerState(),
      user: User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        isOwner: false,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
    );
    addTearDown(state.dispose);

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    await tester.tap(find.text('home'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Manage servers'));
    await tester.pumpAndSettle();

    expect(state.page, MainPage.settings);
    expect(find.text('Servers'), findsOneWidget);
  });
}
