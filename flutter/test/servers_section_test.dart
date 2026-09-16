import 'dart:async';

import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/api/api_service.dart';
import 'package:devinorium_frontend/generated/l10n/app_localizations.dart';
import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/servers/multi_server_state.dart';
import 'package:devinorium_frontend/servers/server_profile.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:devinorium_frontend/views/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeApiService extends ApiService {
  LoginResponse? loginResponse;
  TailscaleInfo? tailscaleInfo;
  String? tailscaleServeError;
  bool? lastServeEnabled;
  int? lastServePort;
  ServerUpdateCheck? updateCheck;
  Object? updateCheckError;
  Completer<ServerUpdateCheck>? updateCheckGate;
  String applyResult = '0.78.0';
  Object? applyError;
  String? serverVersionResult;
  int updateCheckCalls = 0;
  int applyCalls = 0;

  _FakeApiService()
    : super(
        client: ApiClient.withClient(
          MockClient((_) async => http.Response('{}', 200)),
        ),
      );

  @override
  Future<LoginResponse> login({
    required String username,
    required String password,
    String? totp,
  }) async {
    return loginResponse ??
        LoginResponse(
          ok: true,
          totpRequired: false,
          username: 'owner',
          token: 'token',
        );
  }

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
  Future<List<GitConnection>> listGitConnections() async => [];

  @override
  Future<String?> getCloneRoot() async => null;

  @override
  Future<String?> getWorktreeRoot() async => null;

  @override
  Future<TailscaleInfo> tailscaleStatus() async {
    final info = tailscaleInfo;
    if (info == null) throw ApiException('not found', 404);
    return info;
  }

  @override
  Future<TailscaleInfo> setTailscaleServe({
    required bool enabled,
    int? port,
  }) async {
    lastServeEnabled = enabled;
    lastServePort = port;
    final error = tailscaleServeError;
    if (error != null) throw ApiException(error, 502);
    final info = tailscaleInfo;
    if (info == null) throw ApiException('not found', 404);
    return tailscaleInfo = TailscaleInfo(
      localMode: info.localMode,
      installed: info.installed,
      backendState: info.backendState,
      magicDnsName: info.magicDnsName,
      tailnetIpv4: info.tailnetIpv4,
      serveEnabled: enabled,
      serveDesired: enabled,
      servePort: port ?? info.servePort,
      httpsUrl: info.httpsUrl,
      httpsReachable: info.httpsReachable,
      endpoints: info.endpoints,
    );
  }

  @override
  Future<String?> serverVersion() async => serverVersionResult;

  @override
  Future<ServerUpdateCheck> checkServerUpdate() async {
    updateCheckCalls++;
    final gate = updateCheckGate;
    if (gate != null) return gate.future;
    final err = updateCheckError;
    if (err != null) throw err;
    return updateCheck ??
        const ServerUpdateCheck(currentVersion: '0.77.2', updatable: true);
  }

  @override
  Future<String> applyServerUpdate() async {
    applyCalls++;
    final err = applyError;
    if (err != null) throw err;
    return applyResult;
  }
}

Widget _buildWithState(AppState state) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: ChangeNotifierProvider<AppState>.value(
    value: state,
    child: const SettingsPage(),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('Servers section', () {
    AppState buildState({String? serverVersion}) => AppState.test(
      api: _FakeApiService(),
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
      serverVersion: serverVersion,
    );

    testWidgets('shows the add-server button and test profile', (tester) async {
      await tester.pumpWidget(_buildWithState(buildState()));
      await tester.pumpAndSettle();

      expect(find.text('Servers'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Add server'), findsOneWidget);
      // The tile title shows the authed username; the label is the fallback.
      expect(find.text('alice'), findsOneWidget);
      expect(find.text('test'), findsOneWidget);
    });

    testWidgets('shows the connected server version when available', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildWithState(buildState(serverVersion: '0.31.0')),
      );
      await tester.pumpAndSettle();

      expect(find.text('Server version'), findsOneWidget);
      expect(find.text('0.31.0'), findsOneWidget);
    });

    testWidgets('hides the server version row when it is unknown', (
      tester,
    ) async {
      await tester.pumpWidget(_buildWithState(buildState()));
      await tester.pumpAndSettle();

      expect(find.text('Server version'), findsNothing);
      expect(find.text('Servers'), findsOneWidget);
    });

    testWidgets(
      'add-server dialog defaults to https and rejects a scheme in the host',
      (tester) async {
        await tester.pumpWidget(_buildWithState(buildState()));
        await tester.pumpAndSettle();

        await tester.tap(find.widgetWithText(FilledButton, 'Add server'));
        await tester.pumpAndSettle();

        // https:// is the default scheme.
        expect(find.text('https://'), findsOneWidget);

        await tester.enterText(
          find.widgetWithText(TextFormField, 'Server URL'),
          'https://other:7878',
        );
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Username'),
          'owner',
        );
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Password'),
          'pw',
        );

        await tester.tap(find.widgetWithText(TextButton, 'Add server'));
        await tester.pumpAndSettle();

        expect(
          find.text('Do not include http:// or https:// in the server address'),
          findsOneWidget,
        );
      },
    );

    testWidgets('add-server dialog adds a profile', (tester) async {
      await tester.pumpWidget(_buildWithState(buildState()));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'Add server'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Server URL'),
        'other:7878',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Username'),
        'owner',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Password'),
        'pw',
      );
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('http://').last);
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextButton, 'Add server'));
      await tester.pumpAndSettle();

      expect(find.text('owner'), findsOneWidget);
      expect(find.text('other:7878'), findsOneWidget);
    });

    testWidgets('add-server dialog shows an optional TOTP field', (
      tester,
    ) async {
      await tester.pumpWidget(_buildWithState(buildState()));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'Add server'));
      await tester.pumpAndSettle();

      final field = find.widgetWithText(TextFormField, 'TOTP code');
      expect(field, findsOneWidget);
      expect(
        find.text('Optional — only if your account has 2FA enabled'),
        findsOneWidget,
      );

      // An empty TOTP field does not block the form.
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Server URL'),
        'other:7878',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Username'),
        'owner',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Password'),
        'pw',
      );
      await tester.tap(find.widgetWithText(TextButton, 'Add server'));
      await tester.pumpAndSettle();

      expect(find.text('other:7878'), findsOneWidget);
    });

    testWidgets('add-server dialog shows TOTP when required', (tester) async {
      final state = buildState();
      (state.api as _FakeApiService).loginResponse = LoginResponse(
        ok: true,
        totpRequired: true,
        username: 'owner',
      );

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'Add server'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Server URL'),
        'other:7878',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Username'),
        'owner',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Password'),
        'pw',
      );

      await tester.tap(find.widgetWithText(TextButton, 'Add server'));
      await tester.pumpAndSettle();

      expect(find.text('Enter your 6-digit TOTP code.'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, 'TOTP code'), findsOneWidget);
    });

    testWidgets('add-server dialog rejects an empty or invalid host', (
      tester,
    ) async {
      await tester.pumpWidget(_buildWithState(buildState()));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'Add server'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Username'),
        'owner',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Password'),
        'pw',
      );

      for (final host in ['', 'ftp://example.com', 'foo bar']) {
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Server URL'),
          host,
        );
        await tester.tap(find.widgetWithText(TextButton, 'Add server'));
        await tester.pumpAndSettle();

        expect(
          find.text(
            host.isEmpty
                ? 'Required'
                : 'Do not include http:// or https:// in the server address',
          ),
          findsOneWidget,
        );
      }
    });

    testWidgets('cancel keeps the profile', (tester) async {
      final state = buildState();
      await state.addServer(
        serverUrl: 'http://other:7878',
        username: 'owner',
        password: 'pw',
      );

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.delete_outline).at(1));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(find.text('other:7878'), findsOneWidget);
      expect(find.byIcon(Icons.delete_outline), findsNWidgets(2));
    });

    testWidgets('delete button shows a confirmation and removes the profile', (
      tester,
    ) async {
      final state = buildState();
      await state.addServer(
        serverUrl: 'http://other:7878',
        username: 'owner',
        password: 'pw',
      );

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      final deleteButtons = find.byIcon(Icons.delete_outline);
      expect(deleteButtons, findsNWidgets(2));

      await tester.tap(deleteButtons.at(1));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Remove "other" from Devinorium? This will delete the saved connection.',
        ),
        findsOneWidget,
      );

      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(find.text('other:7878'), findsNothing);
      expect(find.byIcon(Icons.delete_outline), findsOneWidget);
    });

    testWidgets(
      'bundled local profile shows This device and no delete button',
      (tester) async {
        final multi = MultiServerState();
        multi.addTestConnection(
          ServerProfile(
            id: MultiServerState.localProfileId,
            label: 'local',
            baseUrl: 'http://127.0.0.1:41234',
            token: 't',
            username: 'local',
            createdAt: DateTime(2024, 1, 1).toUtc(),
            isPrimary: true,
            isLocal: true,
          ),
          _FakeApiService(),
        );
        multi.addTestConnection(
          ServerProfile(
            id: 'remote',
            label: 'remote',
            baseUrl: 'http://remote:7878',
            token: 't2',
            username: 'owner',
            createdAt: DateTime(2024, 1, 2).toUtc(),
          ),
          _FakeApiService(),
        );
        final state = AppState.test(
          multiServerState: multi,
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

        await tester.pumpWidget(_buildWithState(state));
        await tester.pumpAndSettle();

        expect(find.text('This device'), findsOneWidget);
        expect(find.text('Bundled server'), findsOneWidget);
        // Only the remote profile gets a delete button.
        expect(find.byIcon(Icons.delete_outline), findsOneWidget);
      },
    );

    AppState buildLongState() {
      final longUsername = 'ow${'n' * 40}er';
      final longUrl =
          'http://${'a' * 50}.local:7878/very/long/path/that/should/be/ellipsized';

      final multi = MultiServerState();
      multi.addTestConnection(
        ServerProfile(
          id: 'long',
          label: 'long',
          baseUrl: longUrl,
          token: 't',
          username: longUsername,
          createdAt: DateTime(2026, 1, 1).toUtc(),
          isPrimary: true,
        ),
        _FakeApiService(),
      );

      return AppState.test(
        multiServerState: multi,
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
    }

    testWidgets('long server usernames and URLs are ellipsized', (
      tester,
    ) async {
      final longUsername = 'ow${'n' * 40}er';
      final longUrl =
          'http://${'a' * 50}.local:7878/very/long/path/that/should/be/ellipsized';

      await tester.pumpWidget(_buildWithState(buildLongState()));
      await tester.pumpAndSettle();

      final titleFinder = find.text(longUsername);
      expect(titleFinder, findsOneWidget);
      final titleText = tester.widget<Text>(titleFinder);
      expect(titleText.maxLines, 1);
      expect(titleText.overflow, TextOverflow.ellipsis);
      expect(titleText.softWrap, false);

      final urlFinder = find.text(longUrl.substring('http://'.length));
      expect(urlFinder, findsOneWidget);
      final urlText = tester.widget<Text>(urlFinder);
      expect(urlText.maxLines, 1);
      expect(urlText.overflow, TextOverflow.ellipsis);
      expect(urlText.softWrap, false);

      final tooltip = tester.widget<Tooltip>(
        find.ancestor(of: urlFinder, matching: find.byType(Tooltip)),
      );
      expect(tooltip.message, longUrl);
    });

    group('Server update card', () {
      // Owners get an extra "manage" topic, so servers is index 7 for them.
      AppState ownerState(_FakeApiService api) => AppState.test(
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
        settingsTopicIndex: 7,
        serverVersion: '0.77.2',
      );

      testWidgets('is hidden for non-owners', (tester) async {
        final state = buildState();
        addTearDown(state.dispose);
        await tester.pumpWidget(_buildWithState(state));
        await tester.pumpAndSettle();

        expect(find.text('Server update'), findsNothing);
        expect(
          find.byKey(const Key('server_update_check_button')),
          findsNothing,
        );
      });

      testWidgets('check reports an available update', (tester) async {
        final api = _FakeApiService()
          ..updateCheck = const ServerUpdateCheck(
            currentVersion: '0.77.2',
            latestVersion: '0.78.0',
            latestTag: 'v0.78.0',
            updateAvailable: true,
            updatable: true,
          );
        final state = ownerState(api);
        addTearDown(state.dispose);
        await tester.pumpWidget(_buildWithState(state));
        await tester.pumpAndSettle();

        expect(find.text('Server update'), findsOneWidget);
        await tester.tap(find.byKey(const Key('server_update_check_button')));
        await tester.pumpAndSettle();

        expect(api.updateCheckCalls, 1);
        expect(find.text('Version 0.78.0 is available'), findsOneWidget);
        expect(
          find.byKey(const Key('server_update_apply_button')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('server_update_check_button')),
          findsNothing,
        );
      });

      testWidgets('check reports the server is up to date', (tester) async {
        final api = _FakeApiService()
          ..updateCheck = const ServerUpdateCheck(
            currentVersion: '0.77.2',
            latestVersion: '0.77.2',
            latestTag: 'v0.77.2',
            updatable: true,
          );
        final state = ownerState(api);
        addTearDown(state.dispose);
        await tester.pumpWidget(_buildWithState(state));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('server_update_check_button')));
        await tester.pumpAndSettle();

        expect(find.text('The server is up to date'), findsOneWidget);
        // A re-check stays possible.
        expect(
          find.byKey(const Key('server_update_check_button')),
          findsOneWidget,
        );
      });

      testWidgets('a failed check shows an error and keeps the button', (
        tester,
      ) async {
        final api = _FakeApiService()
          ..updateCheckError = ApiException('update check failed', 502);
        final state = ownerState(api);
        addTearDown(state.dispose);
        await tester.pumpWidget(_buildWithState(state));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('server_update_check_button')));
        await tester.pumpAndSettle();

        expect(find.text('Could not check for server updates'), findsOneWidget);
        expect(
          find.byKey(const Key('server_update_check_button')),
          findsOneWidget,
        );
      });

      testWidgets('a bundled server reports itself as not updatable', (
        tester,
      ) async {
        final api = _FakeApiService()
          ..updateCheck = const ServerUpdateCheck(
            currentVersion: '0.77.2',
            updatable: false,
            reason: 'local_mode',
          );
        final state = ownerState(api);
        addTearDown(state.dispose);
        await tester.pumpWidget(_buildWithState(state));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('server_update_check_button')));
        await tester.pumpAndSettle();

        expect(
          find.text('The bundled server is updated together with the app'),
          findsOneWidget,
        );
        // No further action is offered.
        expect(
          find.byKey(const Key('server_update_check_button')),
          findsNothing,
        );
        expect(
          find.byKey(const Key('server_update_apply_button')),
          findsNothing,
        );
      });

      testWidgets('apply asks for confirmation before restarting', (
        tester,
      ) async {
        final api = _FakeApiService()
          ..updateCheck = const ServerUpdateCheck(
            currentVersion: '0.77.2',
            latestVersion: '0.78.0',
            latestTag: 'v0.78.0',
            updateAvailable: true,
            updatable: true,
          );
        final state = ownerState(api);
        addTearDown(state.dispose);
        await tester.pumpWidget(_buildWithState(state));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('server_update_check_button')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('server_update_apply_button')));
        await tester.pumpAndSettle();

        expect(
          find.text(
            'Update the server to 0.78.0? The server restarts and any running work is interrupted.',
          ),
          findsOneWidget,
        );

        await tester.tap(find.widgetWithText(TextButton, 'Update and restart'));
        // The restarting state shows an indeterminate spinner, so the tree
        // never fully settles; pump the dialog away and a frame instead.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(api.applyCalls, 1);
        expect(
          find.text('The server is restarting into version 0.78.0'),
          findsWidgets,
        );
      });

      testWidgets('cancelling the apply dialog does not call the api', (
        tester,
      ) async {
        final api = _FakeApiService()
          ..updateCheck = const ServerUpdateCheck(
            currentVersion: '0.77.2',
            latestVersion: '0.78.0',
            latestTag: 'v0.78.0',
            updateAvailable: true,
            updatable: true,
          );
        final state = ownerState(api);
        addTearDown(state.dispose);
        await tester.pumpWidget(_buildWithState(state));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('server_update_check_button')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('server_update_apply_button')));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
        await tester.pumpAndSettle();

        expect(api.applyCalls, 0);
        // The update offer is still shown.
        expect(find.text('Version 0.78.0 is available'), findsOneWidget);
      });

      testWidgets('a failed apply shows the server error', (tester) async {
        final api = _FakeApiService()
          ..updateCheck = const ServerUpdateCheck(
            currentVersion: '0.77.2',
            latestVersion: '0.78.0',
            latestTag: 'v0.78.0',
            updateAvailable: true,
            updatable: true,
          )
          ..applyError = ApiException('an update is already in progress', 409);
        final state = ownerState(api);
        addTearDown(state.dispose);
        await tester.pumpWidget(_buildWithState(state));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('server_update_check_button')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('server_update_apply_button')));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(TextButton, 'Update and restart'));
        await tester.pumpAndSettle();

        expect(api.applyCalls, 1);
        expect(
          find.text(
            'The server update failed: an update is already in progress',
          ),
          findsOneWidget,
        );
      });

      testWidgets(
        'the restarting card returns to normal once the new version reports',
        (tester) async {
          final api = _FakeApiService()
            ..updateCheck = const ServerUpdateCheck(
              currentVersion: '0.77.2',
              latestVersion: '0.78.0',
              latestTag: 'v0.78.0',
              updateAvailable: true,
              updatable: true,
            );
          final state = ownerState(api);
          addTearDown(state.dispose);
          await tester.pumpWidget(_buildWithState(state));
          await tester.pumpAndSettle();

          await tester.tap(find.byKey(const Key('server_update_check_button')));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const Key('server_update_apply_button')));
          await tester.pumpAndSettle();
          await tester.tap(
            find.widgetWithText(TextButton, 'Update and restart'),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));

          expect(
            find.text('The server is restarting into version 0.78.0'),
            findsWidgets,
          );

          // The health check reconnects and reports the new build; the
          // card leaves the restarting state and offers a fresh check.
          api.serverVersionResult = '0.78.0';
          await state.checkConnection();
          // Let the toast expire; the card must leave the restarting state
          // on its own, not just because the message overlay went away.
          await tester.pump(const Duration(seconds: 5));
          await tester.pumpAndSettle();

          expect(state.serverVersion, '0.78.0');
          expect(
            find.text('The server is restarting into version 0.78.0'),
            findsNothing,
          );
          expect(
            find.byKey(const Key('server_update_check_button')),
            findsOneWidget,
          );
        },
      );

      testWidgets(
        'a check result for the old server does not leak after switching',
        (tester) async {
          final gate = Completer<ServerUpdateCheck>();
          final apiA = _FakeApiService()..updateCheckGate = gate;
          final apiB = _FakeApiService();
          final multi = MultiServerState();
          // The last added connection becomes the active one.
          multi.addTestConnection(
            ServerProfile(
              id: 'b',
              label: 'b',
              baseUrl: 'http://b:7878',
              token: 'tb',
              username: 'owner',
              createdAt: DateTime(2024, 1, 2).toUtc(),
            ),
            apiB,
          );
          multi.addTestConnection(
            ServerProfile(
              id: 'a',
              label: 'a',
              baseUrl: 'http://a:7878',
              token: 'ta',
              username: 'owner',
              createdAt: DateTime(2024, 1, 1).toUtc(),
            ),
            apiA,
          );
          final state = AppState.test(
            multiServerState: multi,
            user: User(
              id: 1,
              username: 'owner',
              role: 'user',
              totpEnabled: false,
              isOwner: true,
              providerId: 'devin-cli',
              providerCommand: 'devin',
            ),
            settingsTopicIndex: 7,
          );
          addTearDown(state.dispose);

          await tester.pumpWidget(_buildWithState(state));
          await tester.pumpAndSettle();
          expect(state.activeServerId, 'a');

          await tester.tap(find.byKey(const Key('server_update_check_button')));
          await tester.pump();

          // Switch away while server A's check is still in flight, then let
          // it complete; the result must not land on server B's card.
          await state.switchServer('b');
          gate.complete(
            const ServerUpdateCheck(
              currentVersion: '0.77.2',
              latestVersion: '0.78.0',
              latestTag: 'v0.78.0',
              updateAvailable: true,
              updatable: true,
            ),
          );
          await tester.pumpAndSettle();

          expect(state.activeServerId, 'b');
          expect(apiA.updateCheckCalls, 1);
          expect(find.text('Version 0.78.0 is available'), findsNothing);
          expect(
            find.byKey(const Key('server_update_check_button')),
            findsOneWidget,
          );
          state.stopHealthChecks();
          state.stopGitRefresh();
        },
      );
    });

    group('Tailscale card', () {
      const tsInfo = TailscaleInfo(
        localMode: false,
        installed: true,
        backendState: 'Running',
        magicDnsName: 'devbox.tail-abc.ts.net',
        tailnetIpv4: ['100.64.1.2'],
        serveEnabled: false,
        servePort: 443,
        endpoints: [
          TailscaleEndpoint(
            kind: 'tailnet-ip',
            label: 'Tailnet IP',
            url: 'http://100.64.1.2:7878',
            reachable: true,
          ),
          TailscaleEndpoint(
            kind: 'magicdns',
            label: 'MagicDNS',
            url: 'http://devbox.tail-abc.ts.net:7878',
            reachable: true,
          ),
        ],
      );

      // Owners get an extra "manage" topic, so servers is index 7 for them.
      AppState tsState({required bool isOwner, TailscaleInfo? info}) =>
          AppState.test(
            api: _FakeApiService()..tailscaleInfo = info,
            user: User(
              id: isOwner ? 1 : 2,
              username: isOwner ? 'owner' : 'alice',
              role: 'user',
              totpEnabled: false,
              isOwner: isOwner,
              providerId: 'devin-cli',
              providerCommand: 'devin',
            ),
            settingsTopicIndex: isOwner ? 7 : 6,
          );

      testWidgets('is hidden while the server has no Tailscale status', (
        tester,
      ) async {
        final state = tsState(isOwner: true);
        addTearDown(state.dispose);
        await tester.pumpWidget(_buildWithState(state));
        await tester.pumpAndSettle();

        expect(find.text('Tailscale'), findsNothing);
      });

      testWidgets('shows endpoints and enables the serve toggle for owners', (
        tester,
      ) async {
        final api = _FakeApiService()..tailscaleInfo = tsInfo;
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
          settingsTopicIndex: 7,
        );
        addTearDown(state.dispose);

        await tester.pumpWidget(_buildWithState(state));
        await tester.pumpAndSettle();

        expect(find.text('Tailscale'), findsOneWidget);
        expect(find.text('Tailnet IP'), findsOneWidget);
        expect(find.text('http://100.64.1.2:7878'), findsOneWidget);
        expect(find.text('MagicDNS'), findsOneWidget);

        final sw = tester.widget<Switch>(
          find.byKey(const Key('tailscale_serve_switch')),
        );
        expect(sw.value, isFalse);
        expect(sw.onChanged, isNotNull);

        await tester.ensureVisible(
          find.byKey(const Key('tailscale_serve_switch')),
        );
        await tester.tap(find.byKey(const Key('tailscale_serve_switch')));
        await tester.pumpAndSettle();
        expect(api.lastServeEnabled, isTrue);
        expect(state.tailscaleInfo?.serveEnabled, isTrue);
      });

      testWidgets('sends the edited port when enabling serve', (tester) async {
        final api = _FakeApiService()..tailscaleInfo = tsInfo;
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
          settingsTopicIndex: 7,
        );
        addTearDown(state.dispose);

        await tester.pumpWidget(_buildWithState(state));
        await tester.pumpAndSettle();

        final field = find.byKey(const Key('tailscale_serve_port'));
        expect(field, findsOneWidget);
        expect(tester.widget<TextField>(field).controller?.text, '443');

        await tester.enterText(field, '8443');
        await tester.ensureVisible(
          find.byKey(const Key('tailscale_serve_switch')),
        );
        await tester.tap(find.byKey(const Key('tailscale_serve_switch')));
        await tester.pumpAndSettle();

        expect(api.lastServeEnabled, isTrue);
        expect(api.lastServePort, 8443);
        expect(state.tailscaleInfo?.servePort, 8443);
      });

      testWidgets('rejects an invalid port without calling the api', (
        tester,
      ) async {
        final api = _FakeApiService()..tailscaleInfo = tsInfo;
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
          settingsTopicIndex: 7,
        );
        addTearDown(state.dispose);

        await tester.pumpWidget(_buildWithState(state));
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byKey(const Key('tailscale_serve_port')),
          '70000',
        );
        await tester.ensureVisible(
          find.byKey(const Key('tailscale_serve_switch')),
        );
        await tester.tap(find.byKey(const Key('tailscale_serve_switch')));
        await tester.pumpAndSettle();

        expect(api.lastServeEnabled, isNull);
        expect(state.globalError, isNotEmpty);
      });

      testWidgets('shows the toggle disabled for non-owners', (tester) async {
        final state = tsState(isOwner: false, info: tsInfo);
        addTearDown(state.dispose);

        await tester.pumpWidget(_buildWithState(state));
        await tester.pumpAndSettle();

        final sw = tester.widget<Switch>(
          find.byKey(const Key('tailscale_serve_switch')),
        );
        expect(sw.onChanged, isNull);
        expect(
          find.text('Only the owner can change Tailscale settings.'),
          findsOneWidget,
        );
      });

      testWidgets('surfaces serve errors via globalError', (tester) async {
        final api = _FakeApiService()
          ..tailscaleInfo = tsInfo
          ..tailscaleServeError = 'tailscale serve failed';
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
          settingsTopicIndex: 7,
        );
        addTearDown(state.dispose);

        await tester.pumpWidget(_buildWithState(state));
        await tester.pumpAndSettle();

        await tester.ensureVisible(
          find.byKey(const Key('tailscale_serve_switch')),
        );
        await tester.tap(find.byKey(const Key('tailscale_serve_switch')));
        await tester.pumpAndSettle();

        expect(api.lastServeEnabled, isTrue);
        expect(state.globalError, 'tailscale serve failed');
      });

      testWidgets('is greyed out on the bundled local server', (tester) async {
        final multi = MultiServerState();
        multi.addTestConnection(
          ServerProfile(
            id: MultiServerState.localProfileId,
            label: 'local',
            baseUrl: 'http://127.0.0.1:41234',
            token: 't',
            username: 'local',
            createdAt: DateTime(2024, 1, 1).toUtc(),
            isPrimary: true,
            isLocal: true,
          ),
          _FakeApiService(),
        );
        final state = AppState.test(
          multiServerState: multi,
          user: User(
            id: 1,
            username: 'local',
            role: 'user',
            totpEnabled: false,
            isOwner: true,
            providerId: 'devin-cli',
            providerCommand: 'devin',
          ),
          settingsTopicIndex: 7,
        );
        addTearDown(state.dispose);

        await tester.pumpWidget(_buildWithState(state));
        await tester.pumpAndSettle();

        expect(find.text('Tailscale'), findsOneWidget);
        expect(
          find.text(
            'Tailscale is not available on the bundled server. Run a standalone server to share it over your Tailnet.',
          ),
          findsOneWidget,
        );
        final sw = tester.widget<Switch>(
          find.byKey(const Key('tailscale_serve_switch')),
        );
        expect(sw.value, isFalse);
        expect(sw.onChanged, isNull);
      });

      testWidgets('repopulates after switching servers', (tester) async {
        final apiWithTs = _FakeApiService()..tailscaleInfo = tsInfo;
        final multi = MultiServerState();
        multi.addTestConnection(
          ServerProfile(
            id: 'ts-server',
            label: 'ts',
            baseUrl: 'http://ts:7878',
            token: 'tb',
            username: 'owner',
            createdAt: DateTime(2024, 1, 2).toUtc(),
          ),
          apiWithTs,
        );
        multi.addTestConnection(
          ServerProfile(
            id: 'plain',
            label: 'plain',
            baseUrl: 'http://plain:7878',
            token: 'ta',
            username: 'u',
            createdAt: DateTime(2024, 1, 1).toUtc(),
            isPrimary: true,
          ),
          _FakeApiService(),
        );
        final state = AppState.test(
          multiServerState: multi,
          user: User(
            id: 1,
            username: 'owner',
            role: 'user',
            totpEnabled: false,
            isOwner: true,
            providerId: 'devin-cli',
            providerCommand: 'devin',
          ),
          settingsTopicIndex: 7,
        );
        addTearDown(state.dispose);

        await tester.pumpWidget(_buildWithState(state));
        await tester.pumpAndSettle();
        // The active server has no tailscale status: card stays hidden.
        expect(find.text('Tailscale'), findsNothing);

        await state.switchServer('ts-server');
        await tester.pumpAndSettle();

        expect(state.activeServerId, 'ts-server');
        expect(state.tailscaleInfo?.magicDnsName, 'devbox.tail-abc.ts.net');
        expect(find.text('Tailscale'), findsOneWidget);
        expect(find.text('Tailnet IP'), findsOneWidget);
        state.stopHealthChecks();
        state.stopGitRefresh();
      });

      testWidgets('drops an unsaved port edit when switching servers', (
        tester,
      ) async {
        final apiWithTs = _FakeApiService()..tailscaleInfo = tsInfo;
        final multi = MultiServerState();
        multi.addTestConnection(
          ServerProfile(
            id: 'ts-server',
            label: 'ts',
            baseUrl: 'http://ts:7878',
            token: 'tb',
            username: 'owner',
            createdAt: DateTime(2024, 1, 2).toUtc(),
          ),
          apiWithTs,
        );
        multi.addTestConnection(
          ServerProfile(
            id: 'plain',
            label: 'plain',
            baseUrl: 'http://plain:7878',
            token: 'ta',
            username: 'u',
            createdAt: DateTime(2024, 1, 1).toUtc(),
            isPrimary: true,
          ),
          _FakeApiService(),
        );
        final state = AppState.test(
          multiServerState: multi,
          user: User(
            id: 1,
            username: 'owner',
            role: 'user',
            totpEnabled: false,
            isOwner: true,
            providerId: 'devin-cli',
            providerCommand: 'devin',
          ),
          settingsTopicIndex: 7,
        );
        addTearDown(state.dispose);

        await tester.pumpWidget(_buildWithState(state));
        await tester.pumpAndSettle();
        await state.switchServer('ts-server');
        await tester.pumpAndSettle();

        final field = find.byKey(const Key('tailscale_serve_port'));
        await tester.enterText(field, '9999');

        // Round-trip through a server with no status: the edit must not
        // survive into the same server's field on return.
        await state.switchServer('plain');
        await tester.pumpAndSettle();
        await state.switchServer('ts-server');
        await tester.pumpAndSettle();

        expect(tester.widget<TextField>(field).controller?.text, '443');
        state.stopHealthChecks();
        state.stopGitRefresh();
      });
    });
  });
}
