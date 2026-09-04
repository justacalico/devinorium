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

  _FakeApiService() : super(client: ApiClient.withClient(MockClient((_) async => http.Response('{}', 200))));

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
  Future<List<GitConnection>> listGitConnections() async => [];

  @override
  Future<String?> getCloneRoot() async => null;
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
          settingsTopicIndex: 5,
          serverVersion: serverVersion,
        );

    testWidgets('shows the add-server button and test profile', (tester) async {
      await tester.pumpWidget(_buildWithState(buildState()));
      await tester.pumpAndSettle();

      expect(find.text('Servers'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Add server'), findsOneWidget);
      expect(find.text('test'), findsOneWidget);
    });

    testWidgets('shows the connected server version when available', (
      tester,
    ) async {
      await tester.pumpWidget(_buildWithState(buildState(serverVersion: '0.31.0')));
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

    testWidgets('add-server dialog requires a URL scheme', (tester) async {
      await tester.pumpWidget(_buildWithState(buildState()));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'Add server'));
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextFormField, 'Server URL'), 'localhost:7878');
      await tester.enterText(find.widgetWithText(TextFormField, 'Username'), 'owner');
      await tester.enterText(find.widgetWithText(TextFormField, 'Password'), 'pw');

      await tester.tap(find.widgetWithText(TextButton, 'Add server'));
      await tester.pumpAndSettle();

      expect(find.text('URL must start with http:// or https://'), findsOneWidget);
    });

    testWidgets('add-server dialog adds a profile', (tester) async {
      await tester.pumpWidget(_buildWithState(buildState()));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'Add server'));
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextFormField, 'Server URL'), 'http://other:7878');
      await tester.enterText(find.widgetWithText(TextFormField, 'Username'), 'owner');
      await tester.enterText(find.widgetWithText(TextFormField, 'Password'), 'pw');

      await tester.tap(find.widgetWithText(TextButton, 'Add server'));
      await tester.pumpAndSettle();

      expect(find.text('other'), findsOneWidget);
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

      await tester.enterText(find.widgetWithText(TextFormField, 'Server URL'), 'http://other:7878');
      await tester.enterText(find.widgetWithText(TextFormField, 'Username'), 'owner');
      await tester.enterText(find.widgetWithText(TextFormField, 'Password'), 'pw');

      await tester.tap(find.widgetWithText(TextButton, 'Add server'));
      await tester.pumpAndSettle();

      expect(find.text('Enter your 6-digit TOTP code.'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, 'TOTP code'), findsOneWidget);
    });

    testWidgets('add-server dialog rejects empty host and invalid schemes', (tester) async {
      await tester.pumpWidget(_buildWithState(buildState()));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'Add server'));
      await tester.pumpAndSettle();

      for (final url in ['http://', 'https://', 'ftp://example.com', 'http://foo bar']) {
        await tester.enterText(find.widgetWithText(TextFormField, 'Server URL'), url);
        await tester.tap(find.widgetWithText(TextButton, 'Add server'));
        await tester.pumpAndSettle();

        expect(find.text('URL must start with http:// or https://'), findsOneWidget);
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

      expect(find.text('other'), findsOneWidget);
      expect(find.byIcon(Icons.delete_outline), findsNWidgets(2));
    });

    testWidgets('delete button shows a confirmation and removes the profile', (tester) async {
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
        find.text('Remove "other" from Devinorium? This will delete the saved connection.'),
        findsOneWidget,
      );

      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(find.text('other'), findsNothing);
      expect(find.byIcon(Icons.delete_outline), findsOneWidget);
    });

    AppState buildLongState() {
      final longLabel = 'lo${'o' * 40}ng';
      final longUrl =
          'http://${'a' * 50}.local:7878/very/long/path/that/should/be/ellipsized';

      final multi = MultiServerState();
      multi.addTestConnection(
        ServerProfile(
          id: 'long',
          label: longLabel,
          baseUrl: longUrl,
          token: 't',
          username: 'owner',
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
        settingsTopicIndex: 5,
      );
    }

    testWidgets('long server labels and URLs are ellipsized', (tester) async {
      final longLabel = 'lo${'o' * 40}ng';
      final longUrl =
          'http://${'a' * 50}.local:7878/very/long/path/that/should/be/ellipsized';

      await tester.pumpWidget(_buildWithState(buildLongState()));
      await tester.pumpAndSettle();

      final labelFinder = find.text(longLabel);
      expect(labelFinder, findsOneWidget);
      final labelText = tester.widget<Text>(labelFinder);
      expect(labelText.maxLines, 1);
      expect(labelText.overflow, TextOverflow.ellipsis);
      expect(labelText.softWrap, false);

      final urlFinder = find.text(longUrl);
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
  });
}
