import 'dart:async';

import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/api/api_service.dart';
import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/services/version_checker.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:devinorium_frontend/theme/theme.dart';
import 'package:devinorium_frontend/views/settings_page.dart';
import 'package:devinorium_frontend/widgets/git_provider_icons.dart';
import 'package:devinorium_frontend/widgets/git_provider_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:devinorium_frontend/generated/l10n/app_localizations.dart';

class _FakeApiService extends ApiService {
  int updateMeCalls = 0;
  int testProviderCalls = 0;
  int providerVersionCalls = 0;
  final List<String?> providerVersionArgs = [];
  int createUserCalls = 0;
  int getCloneRootCalls = 0;
  int setCloneRootCalls = 0;
  int getWorktreeRootCalls = 0;
  int setWorktreeRootCalls = 0;
  String? savedProviderCommand;
  String? testedCommand;
  String? savedCloneRoot;
  String? cloneRootToReturn;
  String? savedWorktreeRoot;
  String? worktreeRootToReturn;
  ProviderVersion? providerVersionToReturn;
  Map<String, ProviderVersion> providerVersionsToReturn = const {};
  Completer<ProviderVersion>? providerVersionGate;
  bool throwOnTest = false;
  Exception? cloneRootError;
  Exception? worktreeRootError;
  List<DirEntry> listFilesToReturn = const [];

  final List<User> _users;
  final List<GitConnection> _gitConnections;

  _FakeApiService({List<User>? users, List<GitConnection>? gitConnections})
    : _users =
          users ??
          [
            User(
              id: 1,
              username: 'owner',
              role: 'user',
              totpEnabled: false,
              isOwner: true,
              providerId: 'devin-cli',
              providerCommand: 'devin',
            ),
          ],
      _gitConnections =
          gitConnections ??
          const [
            GitConnection(id: 'gitlab', name: 'GitLab', enabled: true),
            GitConnection(id: 'github', name: 'GitHub', comingSoon: true),
          ],
      super(
        client: ApiClient.withClient(
          MockClient((_) async => http.Response('{}', 200)),
        ),
      );

  @override
  Future<User> updateMe({
    required String providerId,
    required String providerCommand,
    Map<String, String>? providerCommands,
  }) async {
    updateMeCalls++;
    savedProviderCommand = providerCommand;
    return User(
      id: 1,
      username: 'owner',
      role: 'user',
      totpEnabled: false,
      isOwner: true,
      providerId: providerId,
      providerCommand: providerCommand,
      providerCommands: providerCommands ?? const {},
    );
  }

  @override
  Future<void> testProvider({
    required String providerId,
    required String command,
  }) async {
    testProviderCalls++;
    testedCommand = command;
    if (throwOnTest) throw Exception('not reachable');
  }

  @override
  Future<ProviderVersion> providerVersion({String? provider}) async {
    providerVersionCalls++;
    providerVersionArgs.add(provider);
    final gate = providerVersionGate;
    if (gate != null) return gate.future;
    return providerVersionsToReturn[provider] ??
        providerVersionToReturn ??
        const ProviderVersion();
  }

  @override
  Future<List<User>> listUsers() async => List.unmodifiable(_users);

  @override
  Future<void> createUser({
    required String username,
    required String password,
  }) async {
    createUserCalls++;
    _users.add(
      User(
        id: _users.length + 1,
        username: username,
        role: 'user',
        totpEnabled: false,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
    );
  }

  @override
  Future<List<GitConnection>> listGitConnections() async =>
      List.unmodifiable(_gitConnections);

  @override
  Future<GitConnection> connectGitLab({String? hostname}) async =>
      const GitConnection(
        id: 'gitlab',
        name: 'GitLab',
        enabled: true,
        authed: true,
        account: 'owner',
      );

  @override
  Future<void> disconnectGitLab({String? hostname}) async {}

  @override
  Future<String?> getCloneRoot() async {
    getCloneRootCalls++;
    if (cloneRootError != null) throw cloneRootError!;
    return cloneRootToReturn;
  }

  @override
  Future<String?> setCloneRoot(String? path) async {
    setCloneRootCalls++;
    savedCloneRoot = path;
    if (cloneRootError != null) throw cloneRootError!;
    return path;
  }

  @override
  Future<String?> getWorktreeRoot() async {
    getWorktreeRootCalls++;
    if (worktreeRootError != null) throw worktreeRootError!;
    return worktreeRootToReturn;
  }

  @override
  Future<String?> setWorktreeRoot(String? path) async {
    setWorktreeRootCalls++;
    savedWorktreeRoot = path;
    if (worktreeRootError != null) throw worktreeRootError!;
    return path;
  }

  @override
  Future<List<DirEntry>> listFiles({
    String? path,
    int? projectId,
    String? threadId,
    int? limit,
    int? offset,
  }) async {
    return List.unmodifiable(listFilesToReturn);
  }
}

class _FakeAppState extends AppState {
  final Future<PackageInfo>? packageInfoFuture;

  _FakeAppState.test({
    super.user,
    super.settingsTopicIndex,
    this.packageInfoFuture,
    super.versionChecker,
  }) : super.test(api: _FakeApiService());

  @override
  Future<PackageInfo> packageInfo() => packageInfoFuture ?? super.packageInfo();
}

class _FakeVersionChecker extends VersionChecker {
  final AppUpdate _update;
  int calls = 0;
  Object? error;
  Completer<AppUpdate>? gate;

  _FakeVersionChecker(this._update) : super(client: null);

  @override
  Future<AppUpdate> check(String currentVersion) async {
    calls++;
    final error = this.error;
    if (error != null) throw error;
    final gate = this.gate;
    if (gate != null && !gate.isCompleted) {
      final update = await gate.future;
      return update.copyWith(currentVersion: currentVersion);
    }
    return _update.copyWith(currentVersion: currentVersion);
  }
}

Widget _buildWithState(AppState state) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  locale: state.locale,
  home: MultiProvider(
    providers: [
      ChangeNotifierProvider<AppState>.value(value: state),
      ChangeNotifierProvider<ThemeProvider>(
        create: (_) => ThemeProvider()..loadInitial(),
      ),
    ],
    child: const SettingsPage(),
  ),
);

void main() {
  setUpAll(() {
    PackageInfo.setMockInitialValues(
      appName: 'Devinorium',
      packageName: 'devinorium_frontend',
      version: '0.21.0',
      buildNumber: '25',
      buildSignature: '',
    );
  });

  testWidgets('SettingsPage shows username and TOTP status', (tester) async {
    final state = AppState.test(
      api: _FakeApiService(),
      user: User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: true,
        isOwner: true,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
    );

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    expect(find.text('owner'), findsOneWidget);
    expect(find.text('Enabled'), findsOneWidget);
    expect(find.text('Disable 2FA'), findsOneWidget);

    state.setSettingsTopicIndex(1);
    await tester.pumpAndSettle();

    expect(find.text('Provider'), findsNWidgets(2));
  });

  testWidgets('Provider command field saves on submit', (tester) async {
    final fake = _FakeApiService();
    final state = AppState.test(
      api: fake,
      user: User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        isOwner: true,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
      providers: [ProviderInfo(id: 'devin-cli', name: 'Devin CLI')],
    );

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    state.setSettingsTopicIndex(1);
    await tester.pumpAndSettle();

    final field = find.widgetWithText(TextField, 'Command');
    expect(field, findsOneWidget);

    await tester.enterText(field, 'devin-cli');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(fake.updateMeCalls, 1);
    expect(fake.savedProviderCommand, 'devin-cli');
    expect(state.user?.providerCommand, 'devin-cli');
  });

  testWidgets('Provider test button normalizes empty command to devin', (
    tester,
  ) async {
    final fake = _FakeApiService();
    final state = AppState.test(
      api: fake,
      user: User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        isOwner: true,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
      providers: [ProviderInfo(id: 'devin-cli', name: 'Devin CLI')],
    );

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    state.setSettingsTopicIndex(1);
    await tester.pumpAndSettle();

    final field = find.widgetWithText(TextField, 'Command');
    await tester.enterText(field, '   ');
    await tester.tap(find.widgetWithText(OutlinedButton, 'Test'));
    await tester.pumpAndSettle();

    expect(fake.updateMeCalls, 1);
    expect(fake.savedProviderCommand, 'devin');
    expect(fake.testProviderCalls, 1);
    expect(fake.testedCommand, 'devin');
  });

  testWidgets('Provider test button shows snackbar on success', (tester) async {
    final fake = _FakeApiService();
    final state = AppState.test(
      api: fake,
      user: User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        isOwner: true,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
      providers: [ProviderInfo(id: 'devin-cli', name: 'Devin CLI')],
    );

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    state.setSettingsTopicIndex(1);
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(OutlinedButton, 'Test'));
    await tester.pumpAndSettle();

    expect(find.text('Provider is reachable'), findsOneWidget);
  });

  testWidgets('Provider test button shows error snackbar on failure', (
    tester,
  ) async {
    final fake = _FakeApiService()..throwOnTest = true;
    final state = AppState.test(
      api: fake,
      user: User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        isOwner: true,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
      providers: [ProviderInfo(id: 'devin-cli', name: 'Devin CLI')],
    );

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    state.setSettingsTopicIndex(1);
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(OutlinedButton, 'Test'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Provider test failed'), findsOneWidget);
  });

  testWidgets('Provider card shows installed version', (tester) async {
    final api = _FakeApiService()
      ..providerVersionToReturn = const ProviderVersion(
        providerId: 'devin-cli',
        providerName: 'Devin CLI',
        installedVersion: '3000.6.14',
        latestVersion: '3000.6.14',
      );
    final state = AppState.test(
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
      providers: [ProviderInfo(id: 'devin-cli', name: 'Devin CLI')],
    );

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    state.setSettingsTopicIndex(1);
    await tester.pumpAndSettle();

    expect(find.text('Version'), findsOneWidget);
    expect(find.text('3000.6.14'), findsOneWidget);
    expect(find.text('Up to date'), findsOneWidget);
  });

  testWidgets('Provider card flags an available update', (tester) async {
    final api = _FakeApiService()
      ..providerVersionToReturn = const ProviderVersion(
        providerId: 'devin-cli',
        providerName: 'Devin CLI',
        installedVersion: '3000.6.13',
        latestVersion: '3000.6.14',
        updateAvailable: true,
      );
    final state = AppState.test(
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
      providers: [ProviderInfo(id: 'devin-cli', name: 'Devin CLI')],
    );

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    state.setSettingsTopicIndex(1);
    await tester.pumpAndSettle();

    expect(find.text('3000.6.13'), findsOneWidget);
    expect(find.text('Update available: 3000.6.14'), findsOneWidget);
    expect(find.text('Up to date'), findsNothing);
  });

  testWidgets('Provider card shows a version row for each provider', (
    tester,
  ) async {
    final api = _FakeApiService()
      ..providerVersionsToReturn = const {
        'devin-cli': ProviderVersion(
          providerId: 'devin-cli',
          providerName: 'Devin CLI',
          installedVersion: '3000.6.14',
          latestVersion: '3000.6.14',
        ),
        'opencode': ProviderVersion(
          providerId: 'opencode',
          providerName: 'OpenCode',
          installedVersion: '1.18.27',
          latestVersion: '1.19.0',
          updateAvailable: true,
        ),
      };
    final state = AppState.test(
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
      providers: [
        ProviderInfo(id: 'devin-cli', name: 'Devin CLI'),
        ProviderInfo(id: 'opencode', name: 'OpenCode'),
      ],
    );

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    state.setSettingsTopicIndex(1);
    await tester.pumpAndSettle();

    expect(
      api.providerVersionArgs,
      containsAll(<String>['devin-cli', 'opencode']),
    );
    expect(find.text('Version'), findsNWidgets(2));
    expect(find.text('3000.6.14'), findsOneWidget);
    expect(find.text('Up to date'), findsOneWidget);
    expect(find.text('1.18.27'), findsOneWidget);
    expect(find.text('Update available: 1.19.0'), findsOneWidget);
  });

  testWidgets('Provider version row repaints when the fetch resolves', (
    tester,
  ) async {
    final gate = Completer<ProviderVersion>();
    final api = _FakeApiService()..providerVersionGate = gate;
    final state = AppState.test(
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
      providers: [ProviderInfo(id: 'devin-cli', name: 'Devin CLI')],
    );

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    state.setSettingsTopicIndex(1);
    await tester.pumpAndSettle();

    // The request is still in flight: the row shows the placeholder.
    expect(find.text('—'), findsOneWidget);
    expect(find.text('Up to date'), findsNothing);

    gate.complete(
      const ProviderVersion(
        providerId: 'devin-cli',
        providerName: 'Devin CLI',
        installedVersion: '3000.6.14',
        latestVersion: '3000.6.14',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('3000.6.14'), findsOneWidget);
    expect(find.text('Up to date'), findsOneWidget);
  });

  testWidgets('Provider card shows placeholder when version is unknown', (
    tester,
  ) async {
    final state = AppState.test(
      api: _FakeApiService(),
      user: User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        isOwner: true,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
      providers: [ProviderInfo(id: 'devin-cli', name: 'Devin CLI')],
      providerVersions: const {'devin-cli': ProviderVersion()},
    );

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    state.setSettingsTopicIndex(1);
    await tester.pumpAndSettle();

    expect(find.text('Version'), findsOneWidget);
    expect(find.text('—'), findsOneWidget);
    expect(find.text('Up to date'), findsNothing);
    expect(find.textContaining('Update available'), findsNothing);
  });

  testWidgets('Opening settings refreshes the provider version', (
    tester,
  ) async {
    final fake = _FakeApiService()
      ..providerVersionToReturn = const ProviderVersion(
        providerId: 'devin-cli',
        installedVersion: '3000.6.13',
        latestVersion: '3000.6.14',
        updateAvailable: true,
      );
    final state = AppState.test(
      api: fake,
      user: User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        isOwner: true,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
      providers: [ProviderInfo(id: 'devin-cli', name: 'Devin CLI')],
    );

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    expect(fake.providerVersionCalls, 1);
    expect(fake.providerVersionArgs, ['devin-cli']);
    expect(
      state.providerVersionFor('devin-cli')?.installedVersion,
      '3000.6.13',
    );
    expect(state.providerVersionFor('devin-cli')?.updateAvailable, isTrue);
  });

  testWidgets('Saving the provider command re-checks the version', (
    tester,
  ) async {
    final fake = _FakeApiService();
    final state = AppState.test(
      api: fake,
      user: User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        isOwner: true,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
      providers: [ProviderInfo(id: 'devin-cli', name: 'Devin CLI')],
    );

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();
    expect(fake.providerVersionCalls, 1);

    state.setSettingsTopicIndex(1);
    await tester.pumpAndSettle();

    final field = find.widgetWithText(TextField, 'Command');
    await tester.enterText(field, 'devin-cli');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(fake.providerVersionCalls, 2);
  });

  testWidgets('Saving another provider\'s command re-checks that provider', (
    tester,
  ) async {
    final fake = _FakeApiService();
    final state = AppState.test(
      api: fake,
      user: User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        isOwner: true,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
      providers: [
        ProviderInfo(id: 'devin-cli', name: 'Devin CLI'),
        ProviderInfo(id: 'opencode', name: 'OpenCode'),
      ],
    );

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();
    fake.providerVersionArgs.clear();

    state.setSettingsTopicIndex(1);
    await tester.pumpAndSettle();

    // The second Command field belongs to OpenCode.
    final field = find.widgetWithText(TextField, 'Command').at(1);
    await tester.enterText(field, 'opencode-dev');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(fake.providerVersionArgs, contains('opencode'));
  });

  testWidgets(
    'Provider card shows the user provider version when the list is empty',
    (tester) async {
      final api = _FakeApiService()
        ..providerVersionToReturn = const ProviderVersion(
          providerId: 'devin-cli',
          providerName: 'Devin CLI',
          installedVersion: '3000.6.14',
          latestVersion: '3000.6.14',
        );
      final state = AppState.test(
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
      );

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      state.setSettingsTopicIndex(1);
      await tester.pumpAndSettle();

      // With no provider list loaded the endpoint reports the configured
      // provider, and the single row still shows it.
      expect(api.providerVersionArgs, [null]);
      expect(find.text('Version'), findsOneWidget);
      expect(find.text('3000.6.14'), findsOneWidget);
    },
  );

  testWidgets('Manage section appears for owners', (tester) async {
    final fake = _FakeApiService();
    final state = AppState.test(
      api: fake,
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

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    state.setSettingsTopicIndex(5);
    await tester.pumpAndSettle();

    expect(find.text('Manage'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Create user'), findsOneWidget);
    expect(find.text('owner'), findsWidgets);
  });

  testWidgets('Manage section is hidden for non-owners', (tester) async {
    final fake = _FakeApiService();
    final state = AppState.test(
      api: fake,
      user: User(
        id: 2,
        username: 'alice',
        role: 'user',
        totpEnabled: false,
        isOwner: false,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
    );

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    expect(find.text('Manage'), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Create user'), findsNothing);
  });

  testWidgets('Creating a user adds it to the accounts list', (tester) async {
    final fake = _FakeApiService();
    final state = AppState.test(
      api: fake,
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

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    state.setSettingsTopicIndex(5);
    await tester.pumpAndSettle();

    final openButton = find.widgetWithText(FilledButton, 'Create user');
    await tester.tap(openButton);
    await tester.pumpAndSettle();

    final usernameField = find.widgetWithText(TextField, 'Username');
    final passwordField = find.widgetWithText(TextField, 'Password');
    expect(usernameField, findsOneWidget);
    expect(passwordField, findsOneWidget);

    await tester.enterText(usernameField, 'alice');
    await tester.enterText(passwordField, 'password1234');

    final createButton = find.widgetWithText(FilledButton, 'Create');
    await tester.tap(createButton);
    await tester.pumpAndSettle();

    expect(fake.createUserCalls, 1);
    expect(find.text('alice'), findsOneWidget);
  });

  testWidgets('Settings topic index clamps out of bounds', (tester) async {
    final state = AppState.test(
      user: User(
        id: 2,
        username: 'alice',
        role: 'user',
        totpEnabled: false,
        isOwner: false,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
      settingsTopicIndex: 10,
    );

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    // With 7 sections for non-owners, index 10 clamps to 6 (Servers).
    expect(find.text('Servers'), findsOneWidget);
  });

  testWidgets('Settings redirects to Servers when no server is configured', (
    tester,
  ) async {
    final state = AppState.test(settingsTopicIndex: 0);

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    // Account (index 0) is unavailable without a server, so the page falls
    // back to the Servers section.
    expect(find.text('No servers configured.'), findsOneWidget);

    // Personalization and About stay reachable without a server.
    state.setSettingsTopicIndex(2);
    await tester.pumpAndSettle();
    expect(find.text('Theme'), findsOneWidget);

    state.setSettingsTopicIndex(5);
    await tester.pumpAndSettle();
    expect(find.text('About'), findsWidgets);
  });

  testWidgets('Personalization tab has theme selector', (tester) async {
    final state = AppState.test(
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

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    state.setSettingsTopicIndex(2);
    await tester.pumpAndSettle();

    expect(find.text('Theme'), findsOneWidget);
    // The dropdown shows the active choice (System by default) and exposes
    // the rest of the built-in themes when opened. The language selector
    // shows a second "System", so scope to the theme row's copy.
    expect(find.text('System'), findsNWidgets(2));
    expect(find.text('Import custom'), findsOneWidget);

    await tester.tap(find.text('System').first);
    await tester.pumpAndSettle();

    expect(find.text('Light'), findsOneWidget);
    expect(find.text('Dark'), findsOneWidget);
    expect(find.text('OLED'), findsOneWidget);
  });

  testWidgets('Theme dropdown updates the active theme', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final state = AppState.test(
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

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    state.setSettingsTopicIndex(2);
    await tester.pumpAndSettle();

    // Two "System" labels are on screen (theme and language); the theme
    // selector's copy comes first.
    await tester.tap(find.text('System').first);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Light').last);
    await tester.pumpAndSettle();

    final provider = Provider.of<ThemeProvider>(
      tester.element(find.byType(SettingsPage)),
      listen: false,
    );
    expect(provider.choice, isA<BuiltInThemeChoice>());
    expect((provider.choice as BuiltInThemeChoice).id, BuiltInThemes.lightId);
    // The closed dropdown now reflects the newly selected theme.
    expect(find.text('Light'), findsOneWidget);
  });

  testWidgets(
    'Theme dropdown shows custom hint when a custom theme is loaded',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      const css = ':root { --primary: #ff0000; }';
      final state = AppState.test(
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

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      state.setSettingsTopicIndex(2);
      await tester.pumpAndSettle();

      final provider = Provider.of<ThemeProvider>(
        tester.element(find.byType(SettingsPage)),
        listen: false,
      );
      await provider.loadCustom(css, name: 'Sunset');
      await tester.pumpAndSettle();

      expect(find.text('Custom: Sunset'), findsOneWidget);
    },
  );

  testWidgets('Theme dropdown falls back to bare Custom label without a name', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    const css = ':root { --primary: #ff0000; }';
    final state = AppState.test(
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

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    state.setSettingsTopicIndex(2);
    await tester.pumpAndSettle();

    final provider = Provider.of<ThemeProvider>(
      tester.element(find.byType(SettingsPage)),
      listen: false,
    );
    await provider.loadCustom(css);
    await tester.pumpAndSettle();

    // No name was supplied, so the dropdown hint is just "Custom". The
    // custom-theme info card also renders a "Custom" heading, so both the
    // hint and the heading are present (i.e. the selector is not blank).
    expect(find.text('Custom'), findsNWidgets(2));
  });

  testWidgets('Personalization tab has language selector', (tester) async {
    final state = AppState.test(
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

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    state.setSettingsTopicIndex(2);
    await tester.pumpAndSettle();

    expect(find.text('Language'), findsOneWidget);
    // Language defaults to following the system locale.
    expect(state.language, 'system');
    expect(find.text('System'), findsWidgets);

    await tester.tap(
      find.byWidgetPredicate(
        (w) => w is DropdownButton<String> && w.value == state.language,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('English').last);
    await tester.pumpAndSettle();
    expect(state.language, 'en');
    expect(state.locale, const Locale('en'));
  });

  testWidgets('Language selector can switch to Simplified Chinese', (
    tester,
  ) async {
    final state = AppState.test(
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

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    state.setSettingsTopicIndex(2);
    await tester.pumpAndSettle();

    await tester.tap(
      find.byWidgetPredicate(
        (w) => w is DropdownButton<String> && w.value == state.language,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Simplified Chinese'));
    await tester.pumpAndSettle();
    expect(state.language, 'zh');
    expect(state.locale, const Locale('zh'));
  });

  testWidgets('Language selector can switch back to System', (tester) async {
    final state = AppState.test(
      locale: const Locale('zh'),
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

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    state.setSettingsTopicIndex(2);
    await tester.pumpAndSettle();

    expect(state.language, 'zh');

    await tester.tap(
      find.byWidgetPredicate(
        (w) => w is DropdownButton<String> && w.value == state.language,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('系统').last);
    await tester.pumpAndSettle();
    expect(state.language, 'system');
  });

  testWidgets('Personalization tab renders in Simplified Chinese', (
    tester,
  ) async {
    final state = AppState.test(
      locale: const Locale('zh'),
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

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    state.setSettingsTopicIndex(2);
    await tester.pumpAndSettle();

    expect(find.text('语言'), findsOneWidget);
    expect(find.text('简体中文'), findsOneWidget);
    expect(find.text('默认权限级别'), findsOneWidget);
    expect(find.text('应用于新会话'), findsOneWidget);
  });

  testWidgets('Personalization tab sets the default permission level', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final state = AppState.test(
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

    state.setSettingsTopicIndex(2);
    await tester.pumpAndSettle();

    expect(find.text('Default permission level'), findsOneWidget);
    expect(find.text('Ask every time'), findsOneWidget);

    await tester.tap(find.text('Ask every time'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Smart confirm').last);
    await tester.pumpAndSettle();

    expect(state.defaultPermission, 'smart');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('devinorium_selected_permission'), 'smart');
  });

  testWidgets('Default permission dropdown does not touch the active thread', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final state = AppState.test(
      user: User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        isOwner: true,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
      activeThreadId: 't1',
      selectedPermission: 'bypass',
    );
    addTearDown(state.dispose);

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    state.setSettingsTopicIndex(2);
    await tester.pumpAndSettle();

    // The dropdown shows the default, not the active thread's mode.
    expect(find.text('Ask every time'), findsOneWidget);
    expect(find.text('Auto-run'), findsNothing);

    await tester.tap(find.text('Ask every time'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirm edits').last);
    await tester.pumpAndSettle();

    expect(state.defaultPermission, 'accept-edits');
    expect(state.selectedPermission, 'bypass');
  });

  testWidgets('Git section lists GitLab and GitHub', (tester) async {
    final fake = _FakeApiService();
    final state = AppState.test(
      api: fake,
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

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    state.setSettingsTopicIndex(3);
    await tester.pumpAndSettle();

    expect(find.text('Git'), findsOneWidget);
    expect(find.text('GitLab'), findsOneWidget);
    expect(find.text('GitHub'), findsOneWidget);
    expect(find.text('Coming soon'), findsNWidgets(2));
    expect(find.text('Connect'), findsOneWidget);
  });

  testWidgets('Git section shows provider icons', (tester) async {
    final fake = _FakeApiService();
    final state = AppState.test(
      api: fake,
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

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    state.setSettingsTopicIndex(3);
    await tester.pumpAndSettle();

    expect(find.byType(GitLabIcon), findsOneWidget);
    expect(find.byType(GitHubIcon), findsOneWidget);
    expect(find.byType(SvgPicture), findsNWidgets(2));
  });

  testWidgets('Git section uses a tile per provider', (tester) async {
    final fake = _FakeApiService();
    final state = AppState.test(
      api: fake,
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

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    state.setSettingsTopicIndex(3);
    await tester.pumpAndSettle();

    expect(find.byType(GitProviderTile), findsNWidgets(2));
  });

  testWidgets('Git section shows Disconnect when GitLab is connected', (
    tester,
  ) async {
    final fake = _FakeApiService(
      gitConnections: const [
        GitConnection(
          id: 'gitlab',
          name: 'GitLab',
          enabled: true,
          authed: true,
          account: 'owner',
        ),
        GitConnection(id: 'github', name: 'GitHub', comingSoon: true),
      ],
    );
    final state = AppState.test(
      api: fake,
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

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    state.setSettingsTopicIndex(3);
    await tester.pumpAndSettle();

    expect(find.text('Disconnect'), findsOneWidget);
    expect(find.text('Connect'), findsNothing);
    expect(find.text('Connected as owner'), findsOneWidget);
  });

  testWidgets(
    'Git section shows not installed hint when GitLab is unavailable',
    (tester) async {
      final fake = _FakeApiService(
        gitConnections: const [
          GitConnection(id: 'gitlab', name: 'GitLab'),
          GitConnection(id: 'github', name: 'GitHub', comingSoon: true),
        ],
      );
      final state = AppState.test(
        api: fake,
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

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      state.setSettingsTopicIndex(3);
      await tester.pumpAndSettle();

      expect(find.text('GitLab CLI (glab) is not installed'), findsOneWidget);
      expect(find.text('Connect'), findsNothing);
    },
  );

  testWidgets('Git section falls back to a generic row for unknown providers', (
    tester,
  ) async {
    final fake = _FakeApiService(
      gitConnections: const [GitConnection(id: 'bitbucket', name: 'Bitbucket')],
    );
    final state = AppState.test(
      api: fake,
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

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    state.setSettingsTopicIndex(3);
    await tester.pumpAndSettle();

    expect(find.text('Bitbucket'), findsOneWidget);
    expect(find.text('Not connected'), findsOneWidget);
    expect(find.byType(GitProviderTile), findsOneWidget);
  });

  testWidgets('Clone root section loads current value for owners', (
    tester,
  ) async {
    final fake = _FakeApiService()..cloneRootToReturn = '/srv/clones';
    final state = AppState.test(
      api: fake,
      user: User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        isOwner: true,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
      cloneRoot: '/srv/clones',
    );

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    state.setSettingsTopicIndex(4);
    await tester.pumpAndSettle();

    expect(find.text('Clone root'), findsOneWidget);
    expect(
      find.text('Directory where cloned repositories are placed.'),
      findsOneWidget,
    );
    expect(find.byType(TextField), findsOneWidget);
    expect(state.cloneRoot, '/srv/clones');
    expect(find.widgetWithText(FilledButton, 'Save'), findsOneWidget);
    expect(fake.getCloneRootCalls, greaterThan(0));
  });

  testWidgets('Clone root section is read-only for non-owners', (tester) async {
    final fake = _FakeApiService()..cloneRootToReturn = '/srv/clones';
    final state = AppState.test(
      api: fake,
      user: User(
        id: 2,
        username: 'alice',
        role: 'user',
        totpEnabled: false,
        isOwner: false,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
    );

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    state.setSettingsTopicIndex(4);
    await tester.pumpAndSettle();

    expect(find.text('Clone root'), findsOneWidget);
    expect(find.text('/srv/clones'), findsOneWidget);
    expect(
      find.text('Only the owner can change the clone root.'),
      findsOneWidget,
    );
    expect(find.byType(TextField), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Save'), findsNothing);
  });

  testWidgets('Clone root save propagates to the API and updates state', (
    tester,
  ) async {
    final fake = _FakeApiService();
    final state = AppState.test(
      api: fake,
      user: User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        isOwner: true,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
      cloneRoot: '/old',
    );

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    state.setSettingsTopicIndex(4);
    await tester.pumpAndSettle();

    final field = find.byType(TextField);
    expect(field, findsOneWidget);

    await tester.enterText(field, '/new/clones');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(fake.setCloneRootCalls, 1);
    expect(fake.savedCloneRoot, '/new/clones');
    expect(state.cloneRoot, '/new/clones');
  });

  testWidgets('Clone root save shows an error on failure', (tester) async {
    final fake = _FakeApiService()
      ..cloneRootError = Exception('path must be absolute');
    final state = AppState.test(
      api: fake,
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

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    state.setSettingsTopicIndex(4);
    await tester.pumpAndSettle();

    final field = find.byType(TextField);
    await tester.enterText(field, 'relative');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(state.globalError, contains('path must be absolute'));
    expect(find.textContaining('path must be absolute'), findsOneWidget);
  });

  testWidgets('Clone root browse opens folder picker', (tester) async {
    final fake = _FakeApiService();
    final state = AppState.test(
      api: fake,
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

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    state.setSettingsTopicIndex(4);
    await tester.pumpAndSettle();

    final browse = find.byTooltip('Browse...');
    expect(browse, findsOneWidget);
    await tester.tap(browse);
    await tester.pumpAndSettle();

    expect(find.text('Select current folder'), findsOneWidget);
  });

  testWidgets('Worktree root section loads current value for owners', (
    tester,
  ) async {
    final fake = _FakeApiService()..worktreeRootToReturn = '/srv/worktrees';
    final state = AppState.test(
      api: fake,
      user: User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        isOwner: true,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
      worktreeRoot: '/srv/worktrees',
    );

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    // Owner topic list: account, providers, personalization, git, cloneRoot,
    // manage, about, servers, usage, audit, worktreeRoot.
    state.setSettingsTopicIndex(10);
    await tester.pumpAndSettle();

    expect(find.text('Worktree root'), findsOneWidget);
    expect(
      find.text(
        'Parent directory where worktrees are created. Defaults to the home '
        'directory.',
      ),
      findsOneWidget,
    );
    expect(find.byType(TextField), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Save'), findsOneWidget);
    expect(find.byTooltip('Browse...'), findsOneWidget);
    expect(state.worktreeRoot, '/srv/worktrees');
    expect(fake.getWorktreeRootCalls, greaterThan(0));
  });

  testWidgets('Worktree root section is read-only for non-owners', (
    tester,
  ) async {
    final fake = _FakeApiService()..worktreeRootToReturn = '/srv/worktrees';
    final state = AppState.test(
      api: fake,
      user: User(
        id: 2,
        username: 'member',
        role: 'user',
        totpEnabled: false,
        isOwner: false,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
      worktreeRoot: '/srv/worktrees',
    );

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    // Non-owner topic list: account, providers, personalization, git,
    // cloneRoot, about, servers, usage, worktreeRoot.
    state.setSettingsTopicIndex(8);
    await tester.pumpAndSettle();

    expect(find.text('/srv/worktrees'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Save'), findsNothing);
    expect(
      find.text('Only the owner can change the worktree root.'),
      findsOneWidget,
    );
  });

  testWidgets('Worktree root save propagates to the API and updates state', (
    tester,
  ) async {
    final fake = _FakeApiService();
    final state = AppState.test(
      api: fake,
      user: User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        isOwner: true,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
      worktreeRoot: '/old/worktrees',
    );

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    state.setSettingsTopicIndex(10);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '/srv/new-worktrees');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(fake.setWorktreeRootCalls, 1);
    expect(fake.savedWorktreeRoot, '/srv/new-worktrees');
    expect(state.worktreeRoot, '/srv/new-worktrees');
    expect(state.globalError, isEmpty);
  });

  testWidgets('Worktree root browse opens folder picker with custom title', (
    tester,
  ) async {
    final fake = _FakeApiService();
    final state = AppState.test(
      api: fake,
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

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    state.setSettingsTopicIndex(10);
    await tester.pumpAndSettle();

    final browse = find.byTooltip('Browse...');
    expect(browse, findsOneWidget);
    await tester.tap(browse);
    await tester.pumpAndSettle();

    // The dialog is titled after the worktree root setting, not clone root.
    expect(
      find.descendant(
        of: find.byType(Dialog),
        matching: find.text('Worktree root'),
      ),
      findsOneWidget,
    );
    expect(find.text('Select current folder'), findsOneWidget);
  });

  testWidgets('app bar title is left aligned and ellipsized', (tester) async {
    final state = AppState.test(
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

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    final appBar = tester.widget<AppBar>(find.byType(AppBar));
    expect(appBar.centerTitle, isFalse);

    final titleText = tester.widget<Text>(
      find.descendant(of: find.byType(AppBar), matching: find.text('Settings')),
    );
    expect(titleText.maxLines, 1);
    expect(titleText.overflow, TextOverflow.ellipsis);
  });

  testWidgets('About section shows app name, version, license and links', (
    tester,
  ) async {
    final state = AppState.test(
      api: _FakeApiService(),
      settingsTopicIndex: 6,
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

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    expect(find.text('About'), findsOneWidget);
    expect(find.text('Bring your agents anywhere'), findsOneWidget);
    expect(find.text('App name'), findsOneWidget);
    expect(find.text('Devinorium'), findsOneWidget);
    expect(find.text('Version'), findsOneWidget);
    expect(find.text('0.21.0'), findsOneWidget);
    expect(find.text('License'), findsOneWidget);
    expect(find.text('AGPL-3.0-only'), findsOneWidget);
    expect(find.text('Source code'), findsOneWidget);
    expect(find.text('Support'), findsOneWidget);
    expect(find.text('Privacy policy'), findsOneWidget);
    expect(
      find.text('https://gitlab.com/HttpAnimations/devinorium'),
      findsOneWidget,
    );
    expect(
      find.text('https://gitlab.com/HttpAnimations/devinorium/-/work_items'),
      findsOneWidget,
    );
    expect(
      find.text(
        'https://gitlab.com/HttpAnimations/devinorium/-/blob/main/privacy_policy.md',
      ),
      findsOneWidget,
    );
  });

  testWidgets('About section is available for non-owners', (tester) async {
    final state = AppState.test(
      api: _FakeApiService(),
      settingsTopicIndex: 5,
      user: User(
        id: 2,
        username: 'alice',
        role: 'user',
        totpEnabled: false,
        isOwner: false,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
    );

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    expect(find.text('About'), findsOneWidget);
    expect(find.text('AGPL-3.0-only'), findsOneWidget);
  });

  testWidgets('About section shows loading while package info loads', (
    tester,
  ) async {
    final state = _FakeAppState.test(
      settingsTopicIndex: 6,
      user: User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        isOwner: true,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
      packageInfoFuture: Future.delayed(
        const Duration(seconds: 1),
        () => PackageInfo(
          appName: 'Devinorium',
          packageName: 'devinorium_frontend',
          version: '0.21.0',
          buildNumber: '25',
          buildSignature: '',
        ),
      ),
    );

    await tester.pumpWidget(_buildWithState(state));
    await tester.pump();

    expect(find.text('Loading…'), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));

    expect(find.text('0.21.0'), findsOneWidget);
  });

  testWidgets('About section falls back when version is empty', (tester) async {
    final state = _FakeAppState.test(
      settingsTopicIndex: 6,
      user: User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        isOwner: true,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
      packageInfoFuture: Future.value(
        PackageInfo(
          appName: 'Devinorium',
          packageName: 'devinorium_frontend',
          version: '',
          buildNumber: '25',
          buildSignature: '',
        ),
      ),
    );

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    expect(find.text('—'), findsOneWidget);
  });

  testWidgets('About section shows error when package info fails', (
    tester,
  ) async {
    final state = _FakeAppState.test(
      settingsTopicIndex: 6,
      user: User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        isOwner: true,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
      packageInfoFuture: Future<PackageInfo>.delayed(
        const Duration(seconds: 1),
        () => throw Exception('package info failed'),
      ),
    );

    await tester.pumpWidget(_buildWithState(state));
    await tester.pump();

    expect(find.text('Loading…'), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));

    expect(find.text('Error'), findsOneWidget);
  });

  testWidgets('About section opens source code and support links', (
    tester,
  ) async {
    final launched = <String>[];
    const channel = MethodChannel('plugins.flutter.io/url_launcher');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'canLaunch':
              return true;
            case 'launch':
              final args = call.arguments as Map<dynamic, dynamic>;
              launched.add(args['url'] as String);
              return true;
          }
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      launched.clear();
    });

    final state = _FakeAppState.test(
      settingsTopicIndex: 6,
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

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Source code'));
    await tester.pumpAndSettle();

    expect(launched, contains('https://gitlab.com/HttpAnimations/devinorium'));

    await tester.tap(find.text('Support'));
    await tester.pumpAndSettle();

    expect(
      launched,
      contains('https://gitlab.com/HttpAnimations/devinorium/-/work_items'),
    );
  });

  testWidgets('About section opens the privacy policy link', (tester) async {
    final launched = <String>[];
    const channel = MethodChannel('plugins.flutter.io/url_launcher');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'canLaunch':
              return true;
            case 'launch':
              final args = call.arguments as Map<dynamic, dynamic>;
              launched.add(args['url'] as String);
              return true;
          }
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      launched.clear();
    });

    final state = _FakeAppState.test(
      settingsTopicIndex: 6,
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

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Privacy policy'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Privacy policy'));
    await tester.pumpAndSettle();

    expect(
      launched,
      contains(
        'https://gitlab.com/HttpAnimations/devinorium/-/blob/main/privacy_policy.md',
      ),
    );
  });

  testWidgets('About section shows the current version', (tester) async {
    final state = _FakeAppState.test(
      settingsTopicIndex: 6,
      user: User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        isOwner: true,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
      packageInfoFuture: Future.value(
        PackageInfo(
          appName: 'Devinorium',
          packageName: 'devinorium_frontend',
          version: '0.40.2',
          buildNumber: '51',
          buildSignature: '',
        ),
      ),
    );

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    expect(find.text('0.40.2'), findsOneWidget);
  });

  testWidgets(
    'About section shows an update chip when a newer release exists',
    (tester) async {
      final checker = _FakeVersionChecker(
        AppUpdate(
          latestVersion: '0.40.3',
          updateAvailable: true,
          releaseUrl: '${VersionChecker.releasesUrl}/v0.40.3',
        ),
      );
      final state = _FakeAppState.test(
        settingsTopicIndex: 6,
        user: User(
          id: 1,
          username: 'owner',
          role: 'user',
          totpEnabled: false,
          isOwner: true,
          providerId: 'devin-cli',
          providerCommand: 'devin',
        ),
        packageInfoFuture: Future.value(
          PackageInfo(
            appName: 'Devinorium',
            packageName: 'devinorium_frontend',
            version: '0.40.2',
            buildNumber: '51',
            buildSignature: '',
          ),
        ),
        versionChecker: checker,
      );

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      expect(find.text('Update available: 0.40.3'), findsNothing);
      expect(checker.calls, 0);

      await tester.tap(find.text('Check for updates'));
      await tester.pumpAndSettle();

      expect(checker.calls, 1);
      expect(find.text('Update available: 0.40.3'), findsOneWidget);
    },
  );

  testWidgets('About section reports up to date when no update is found', (
    tester,
  ) async {
    final checker = _FakeVersionChecker(
      AppUpdate(releaseUrl: VersionChecker.releasesUrl),
    );
    final state = _FakeAppState.test(
      settingsTopicIndex: 6,
      user: User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        isOwner: true,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
      versionChecker: checker,
    );

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Check for updates'));
    await tester.pumpAndSettle();

    expect(checker.calls, 1);
    expect(find.text('You are on the latest version'), findsOneWidget);
    expect(find.textContaining('Update available'), findsNothing);
  });

  testWidgets('About section shows an error when the update check fails', (
    tester,
  ) async {
    final checker = _FakeVersionChecker(
      AppUpdate(releaseUrl: VersionChecker.releasesUrl),
    )..error = Exception('offline');
    final state = _FakeAppState.test(
      settingsTopicIndex: 6,
      user: User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        isOwner: true,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
      versionChecker: checker,
    );

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Check for updates'));
    await tester.pumpAndSettle();

    expect(checker.calls, 1);
    expect(find.text('Could not check for updates'), findsOneWidget);
    expect(find.text('You are on the latest version'), findsNothing);
  });

  testWidgets('Check for updates button is disabled while a check runs', (
    tester,
  ) async {
    final checker = _FakeVersionChecker(
      AppUpdate(
        latestVersion: '0.40.3',
        updateAvailable: true,
        releaseUrl: '${VersionChecker.releasesUrl}/v0.40.3',
      ),
    )..gate = Completer<AppUpdate>();
    final state = _FakeAppState.test(
      settingsTopicIndex: 6,
      user: User(
        id: 1,
        username: 'owner',
        role: 'user',
        totpEnabled: false,
        isOwner: true,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
      versionChecker: checker,
    );

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Check for updates'));
    await tester.pump();

    expect(checker.calls, 1);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.tap(find.text('Check for updates'));
    await tester.pump();
    expect(checker.calls, 1);

    checker.gate!.complete(
      AppUpdate(
        latestVersion: '0.40.3',
        updateAvailable: true,
        releaseUrl: '${VersionChecker.releasesUrl}/v0.40.3',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Update available: 0.40.3'), findsOneWidget);
  });

  testWidgets(
    'About section opens the release page when the version row is tapped and an update is available',
    (tester) async {
      final launched = <String>[];
      const channel = MethodChannel('plugins.flutter.io/url_launcher');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            switch (call.method) {
              case 'canLaunch':
                return true;
              case 'launch':
                final args = call.arguments as Map<dynamic, dynamic>;
                launched.add(args['url'] as String);
                return true;
            }
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        launched.clear();
      });

      final state = _FakeAppState.test(
        settingsTopicIndex: 6,
        user: User(
          id: 1,
          username: 'owner',
          role: 'user',
          totpEnabled: false,
          isOwner: true,
          providerId: 'devin-cli',
          providerCommand: 'devin',
        ),
        packageInfoFuture: Future.value(
          PackageInfo(
            appName: 'Devinorium',
            packageName: 'devinorium_frontend',
            version: '0.40.2',
            buildNumber: '51',
            buildSignature: '',
          ),
        ),
        versionChecker: _FakeVersionChecker(
          AppUpdate(
            latestVersion: '0.40.3',
            updateAvailable: true,
            releaseUrl: '${VersionChecker.releasesUrl}/v0.40.3',
          ),
        ),
      );

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Check for updates'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('0.40.2'));
      await tester.pumpAndSettle();

      expect(launched, contains('${VersionChecker.releasesUrl}/v0.40.3'));
    },
  );

  testWidgets('About section opens the releases link', (tester) async {
    final launched = <String>[];
    const channel = MethodChannel('plugins.flutter.io/url_launcher');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'canLaunch':
              return true;
            case 'launch':
              final args = call.arguments as Map<dynamic, dynamic>;
              launched.add(args['url'] as String);
              return true;
          }
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      launched.clear();
    });

    final state = _FakeAppState.test(
      settingsTopicIndex: 6,
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

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Releases'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Releases'));
    await tester.pumpAndSettle();

    expect(launched, contains(VersionChecker.releasesUrl));
  });

  testWidgets('About section shows a snackbar when a link fails to open', (
    tester,
  ) async {
    const channel = MethodChannel('plugins.flutter.io/url_launcher');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'canLaunch':
              return true;
            case 'launch':
              return false;
          }
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    final state = _FakeAppState.test(
      settingsTopicIndex: 6,
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

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Source code'));
    await tester.pumpAndSettle();

    expect(
      find.text('Could not open https://gitlab.com/HttpAnimations/devinorium'),
      findsOneWidget,
    );
  });
}
