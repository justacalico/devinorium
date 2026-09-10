import 'dart:convert';

import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/api/api_service.dart';
import 'package:devinorium_frontend/generated/l10n/app_localizations.dart';
import 'package:devinorium_frontend/generated/l10n/app_localizations_en.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:devinorium_frontend/views/dialogs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response _json(int status, Object body) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

ApiClient _clientFor(List<http.Response> responses) {
  var index = 0;
  return ApiClient.withClient(
    MockClient((req) async {
      if (index >= responses.length) {
        return _json(404, {'error': 'unexpected request to ${req.url.path}'});
      }
      return responses[index++];
    }),
  );
}

void main() {
  testWidgets('WebLoginDialog signs in and dismisses', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final state = AppState.test(
      api: ApiService(
        client: _clientFor([
          _json(200, {
            'ok': true,
            'totp_required': false,
            'username': 'owner',
            'token': 'abc',
          }),
          _json(200, {
            'id': 1,
            'username': 'owner',
            'role': 'user',
            'is_owner': true,
            'totp_enabled': false,
            'provider_id': 'devin-cli',
            'provider_command': 'devin',
          }),
          _json(200, []),
          _json(200, []),
          _json(200, []),
          _json(200, []),
          _json(200, {}),
          _json(200, {'version': '0.1.0'}),
        ]),
      ),
      dialog: DialogKind.webLogin,
    );

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ChangeNotifierProvider<AppState>.value(
          value: state,
          child: const DialogLayer(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final l = AppLocalizationsEn();
    expect(find.text(l.signInToYourAccount), findsOneWidget);

    final fields = find.byType(TextFormField);
    expect(fields, findsNWidgets(3));

    await tester.enterText(fields.at(0), 'owner');
    await tester.enterText(fields.at(1), 'pw');
    await tester.tap(find.widgetWithText(FilledButton, l.signIn));

    await tester.pump();
    await tester.pumpAndSettle();

    expect(state.user?.username, 'owner');
    expect(state.dialog, DialogKind.none);
    expect(find.text(l.signInToYourAccount), findsNothing);

    state.stopHealthChecks();
    state.stopGitRefresh();
  });

  testWidgets('WebLoginDialog shows TOTP field after first factor', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final state = AppState.test(
      api: ApiService(
        client: _clientFor([
          _json(200, {
            'ok': true,
            'totp_required': true,
            'username': 'owner',
          }),
        ]),
      ),
      dialog: DialogKind.webLogin,
    );

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ChangeNotifierProvider<AppState>.value(
          value: state,
          child: const DialogLayer(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final l = AppLocalizationsEn();
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'owner');
    await tester.enterText(fields.at(1), 'pw');
    await tester.tap(find.widgetWithText(FilledButton, l.signIn));

    await tester.pump();
    await tester.pumpAndSettle();

    expect(state.dialog, DialogKind.webLogin);
    expect(find.text(l.totpOptional), findsNothing);
  });
}
