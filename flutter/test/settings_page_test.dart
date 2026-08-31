import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/api/api_service.dart';
import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:devinorium_frontend/views/settings_page.dart';
import 'package:devinorium_frontend/widgets/git_provider_icons.dart';
import 'package:devinorium_frontend/widgets/git_provider_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeApiService extends ApiService {
  int updateMeCalls = 0;
  int testProviderCalls = 0;
  int createUserCalls = 0;
  int revokeDeviceCalls = 0;
  int getCloneRootCalls = 0;
  int setCloneRootCalls = 0;
  String? savedProviderCommand;
  String? testedCommand;
  String? savedCloneRoot;
  String? cloneRootToReturn;
  bool throwOnTest = false;
  Exception? cloneRootError;
  List<DirEntry> listFilesToReturn = const [];

  final List<User> _users;
  final List<Device> _devices;
  final List<GitConnection> _gitConnections;

  _FakeApiService({
    List<User>? users,
    List<Device>? devices,
    List<GitConnection>? gitConnections,
  })  : _users = users ??
            [User(
              id: 1,
              username: 'owner',
              role: 'user',
              totpEnabled: false,
              isOwner: true,
              providerId: 'devin-cli',
              providerCommand: 'devin',
            )],
        _devices = devices ??
            [Device(
              deviceId: 'dev1',
              tokenPrefix: 'abc',
              name: 'Phone',
              createdAt: '',
              lastSeenAt: '',
              expiresAt: '',
              isCurrent: true,
            )],
        _gitConnections = gitConnections ??
            const [
              GitConnection(id: 'gitlab', name: 'GitLab', enabled: true),
              GitConnection(id: 'github', name: 'GitHub', comingSoon: true),
            ],
        super(client: ApiClient.withClient(MockClient((_) async => http.Response('{}', 200))));

  @override
  Future<User> updateMe({
    required String providerId,
    required String providerCommand,
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
  Future<List<User>> listUsers() async => List.unmodifiable(_users);

  @override
  Future<void> createUser({
    required String username,
    required String password,
  }) async {
    createUserCalls++;
    _users.add(User(
      id: _users.length + 1,
      username: username,
      role: 'user',
      totpEnabled: false,
      providerId: 'devin-cli',
      providerCommand: 'devin',
    ));
  }

  @override
  Future<List<Device>> listDevices() async => List.unmodifiable(_devices);

  @override
  Future<List<GitConnection>> listGitConnections() async =>
      List.unmodifiable(_gitConnections);

  @override
  Future<GitConnection> connectGitLab({String? hostname}) async =>
      const GitConnection(id: 'gitlab', name: 'GitLab', enabled: true, authed: true, account: 'owner');

  @override
  Future<void> disconnectGitLab({String? hostname}) async {}

  @override
  Future<void> revokeDevice(String deviceId) async {
    revokeDeviceCalls++;
    _devices.removeWhere((d) => d.deviceId == deviceId);
  }

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
  Future<List<DirEntry>> listFiles({
    String? path,
    int? projectId,
    int? limit,
    int? offset,
  }) async {
    return List.unmodifiable(listFilesToReturn);
  }
}

Widget _buildWithState(AppState state) => MaterialApp(
      home: ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const SettingsPage(),
      ),
    );

void main() {
  testWidgets('SettingsPage shows username and TOTP status', (tester) async {
    final state = AppState.test(
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

  testWidgets('Provider test button normalizes empty command to devin', (tester) async {
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

  testWidgets('Provider test button shows error snackbar on failure', (tester) async {
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

    state.setSettingsTopicIndex(6);
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

  testWidgets('Devices section lists paired devices', (tester) async {
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

    state.setSettingsTopicIndex(2);
    await tester.pumpAndSettle();

    expect(find.text('Devices'), findsOneWidget);
    expect(find.text('Phone'), findsOneWidget);
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

    state.setSettingsTopicIndex(6);
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

    // With 6 sections for non-owners, index 10 clamps to 5 (Clone root).
    expect(find.text('Clone root'), findsOneWidget);
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

    state.setSettingsTopicIndex(3);
    await tester.pumpAndSettle();

    expect(find.text('Theme'), findsOneWidget);
    expect(find.text('Light'), findsOneWidget);
    expect(find.text('Dark'), findsOneWidget);
    expect(find.text('System'), findsOneWidget);
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

    state.setSettingsTopicIndex(3);
    await tester.pumpAndSettle();

    expect(find.text('Language'), findsOneWidget);
    expect(find.text('English'), findsOneWidget);

    await tester.tap(find.text('English'));
    await tester.pumpAndSettle();
    expect(state.locale, const Locale('en'));
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

    state.setSettingsTopicIndex(4);
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

    state.setSettingsTopicIndex(4);
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

    state.setSettingsTopicIndex(4);
    await tester.pumpAndSettle();

    expect(find.byType(GitProviderTile), findsNWidgets(2));
  });

  testWidgets('Git section shows Disconnect when GitLab is connected', (tester) async {
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

    state.setSettingsTopicIndex(4);
    await tester.pumpAndSettle();

    expect(find.text('Disconnect'), findsOneWidget);
    expect(find.text('Connect'), findsNothing);
    expect(find.text('Connected as owner'), findsOneWidget);
  });

  testWidgets('Git section shows not installed hint when GitLab is unavailable', (tester) async {
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

    state.setSettingsTopicIndex(4);
    await tester.pumpAndSettle();

    expect(find.text('GitLab CLI (glab) is not installed'), findsOneWidget);
    expect(find.text('Connect'), findsNothing);
  });

  testWidgets('Git section falls back to a generic row for unknown providers', (tester) async {
    final fake = _FakeApiService(
      gitConnections: const [
        GitConnection(id: 'bitbucket', name: 'Bitbucket'),
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

    state.setSettingsTopicIndex(4);
    await tester.pumpAndSettle();

    expect(find.text('Bitbucket'), findsOneWidget);
    expect(find.text('Not connected'), findsOneWidget);
    expect(find.byType(GitProviderTile), findsOneWidget);
  });

  testWidgets('Clone root section loads current value for owners', (tester) async {
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

    state.setSettingsTopicIndex(5);
    await tester.pumpAndSettle();

    expect(find.text('Clone root'), findsOneWidget);
    expect(find.text('Directory where cloned repositories are placed.'), findsOneWidget);
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

    state.setSettingsTopicIndex(5);
    await tester.pumpAndSettle();

    expect(find.text('Clone root'), findsOneWidget);
    expect(find.text('/srv/clones'), findsOneWidget);
    expect(find.text('Only the owner can change the clone root.'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Save'), findsNothing);
  });

  testWidgets('Clone root save propagates to the API and updates state', (tester) async {
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

    state.setSettingsTopicIndex(5);
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
    final fake = _FakeApiService()..cloneRootError = Exception('path must be absolute');
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

    state.setSettingsTopicIndex(5);
    await tester.pumpAndSettle();

    final browse = find.byTooltip('Browse...');
    expect(browse, findsOneWidget);
    await tester.tap(browse);
    await tester.pumpAndSettle();

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
}
