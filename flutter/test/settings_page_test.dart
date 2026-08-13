import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/api/api_service.dart';
import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:devinorium_frontend/views/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeApiService extends ApiService {
  int updateMeCalls = 0;
  int testProviderCalls = 0;
  String? savedProviderCommand;
  String? testedCommand;
  bool throwOnTest = false;

  _FakeApiService() : super(client: ApiClient.withClient(MockClient((_) async => http.Response('{}', 200))));

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
      role: 'owner',
      totpEnabled: false,
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
        role: 'owner',
        totpEnabled: true,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
    );

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    expect(find.text('owner'), findsOneWidget);
    expect(find.text('Enabled'), findsOneWidget);
    expect(find.text('Disable 2FA'), findsOneWidget);
    expect(find.text('Provider'), findsNWidgets(2));
  });

  testWidgets('Provider command field saves on submit', (tester) async {
    final fake = _FakeApiService();
    final state = AppState.test(
      api: fake,
      user: User(
        id: 1,
        username: 'owner',
        role: 'owner',
        totpEnabled: false,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
      providers: [ProviderInfo(id: 'devin-cli', name: 'Devin CLI')],
    );

    await tester.pumpWidget(_buildWithState(state));
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
        role: 'owner',
        totpEnabled: false,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
      providers: [ProviderInfo(id: 'devin-cli', name: 'Devin CLI')],
    );

    await tester.pumpWidget(_buildWithState(state));
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
        role: 'owner',
        totpEnabled: false,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
      providers: [ProviderInfo(id: 'devin-cli', name: 'Devin CLI')],
    );

    await tester.pumpWidget(_buildWithState(state));
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
        role: 'owner',
        totpEnabled: false,
        providerId: 'devin-cli',
        providerCommand: 'devin',
      ),
      providers: [ProviderInfo(id: 'devin-cli', name: 'Devin CLI')],
    );

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(OutlinedButton, 'Test'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Provider test failed'), findsOneWidget);
  });
}
