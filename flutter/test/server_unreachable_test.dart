import 'dart:async';
import 'dart:convert';

import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/api/api_service.dart';
import 'package:devinorium_frontend/generated/l10n/app_localizations.dart';
import 'package:devinorium_frontend/generated/l10n/app_localizations_en.dart';
import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/services/local_server.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:devinorium_frontend/views/thread_page.dart';
import 'package:fake_async/fake_async.dart';
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

/// MockClient that throws like a dead server while [down] is set and routes
/// the bootstrap endpoints once it "comes back".
ApiClient _flakyClient({required bool Function() down}) {
  return ApiClient.withClient(
    MockClient((req) async {
      if (down()) {
        throw http.ClientException('connection refused', req.url);
      }
      return switch (req.url.path) {
        '/healthz' => _json(200, {}),
        '/api/server/version' => _json(200, {'version': '0.1'}),
        '/api/auth/me' => _json(200, {
          'id': 1,
          'username': 'owner',
          'role': 'user',
          'is_owner': true,
          'totp_enabled': false,
          'provider_id': 'devin-cli',
          'provider_command': 'devin',
        }),
        '/api/federation/nodes' => _json(200, {
          'self_name': 'hub',
          'nodes': [],
        }),
        _ => _json(200, []),
      };
    }),
  );
}

Future<void> _pumpUntil(bool Function() ready) async {
  for (var i = 0; i < 100 && !ready(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Widget _buildWithState(AppState state) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: ChangeNotifierProvider<AppState>.value(
    value: state,
    child: const ThreadPage(),
  ),
);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('request timeouts', () {
    test('checkHealth returns false when the server never answers', () {
      fakeAsync((async) {
        final service = ApiService(
          client: ApiClient.withClient(
            MockClient((_) => Completer<http.Response>().future),
          ),
        );
        var result = true;
        service.checkHealth().then((v) => result = v);
        async.elapse(const Duration(seconds: 10));
        expect(result, isFalse);
      });
    });

    test('me reports a friendly error when the request times out', () {
      fakeAsync((async) {
        final service = ApiService(
          client: ApiClient.withClient(
            MockClient((_) => Completer<http.Response>().future),
          ),
        );
        Object? error;
        service.me().catchError((Object e) {
          error = e;
          return User(
            id: 0,
            username: '',
            role: '',
            totpEnabled: false,
            providerId: '',
            providerCommand: '',
          );
        });
        async.elapse(const Duration(seconds: 20));
        expect(error, isA<ApiException>());
        expect((error! as ApiException).message, isNotEmpty);
      });
    });
  });

  group('unreachable server', () {
    test(
      'bootstrap lands on the app disconnected instead of hanging',
      () async {
        var down = true;
        final state = AppState(
          api: ApiService(client: _flakyClient(down: () => down)),
          localServerManager: LocalServerManager.disabled(),
        );
        addTearDown(state.dispose);

        await state.bootstrap();

        expect(state.view, AppView.app);
        expect(state.user, isNull);
        expect(state.connectionStatus, ConnectionStatus.disconnected);
      },
    );

    test(
      'bootstrap finishes the deferred load once the server is back',
      () async {
        var down = true;
        final state = AppState(
          api: ApiService(client: _flakyClient(down: () => down)),
          localServerManager: LocalServerManager.disabled(),
        );
        addTearDown(state.dispose);

        await state.bootstrap();
        expect(state.connectionStatus, ConnectionStatus.disconnected);

        down = false;
        await state.checkConnection();
        await _pumpUntil(() => state.user != null);

        expect(state.connectionStatus, ConnectionStatus.connected);
        expect(state.user?.username, 'owner');
      },
    );

    test('switchServer to a dead server reports disconnected', () async {
      var down = true;
      final state = AppState.test(
        api: ApiService(client: _flakyClient(down: () => down)),
      );
      addTearDown(state.dispose);

      // The profile the test constructor registered is unreachable until
      // the flag flips; switching to it must not stall on a dead socket.
      await state.switchServer('test');

      expect(state.activeServerId, 'test');
      expect(state.connectionStatus, ConnectionStatus.disconnected);
      expect(state.user, isNull);

      down = false;
      await state.checkConnection();
      await _pumpUntil(() => state.user != null);
      expect(state.user?.username, 'owner');
    });
  });

  group('thread page empty state', () {
    final l = AppLocalizationsEn();

    testWidgets('shows the unreachable state with a retry button', (
      tester,
    ) async {
      var down = true;
      final state = AppState.test(
        api: ApiService(client: _flakyClient(down: () => down)),
        connectionStatus: ConnectionStatus.disconnected,
      );
      addTearDown(state.dispose);

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      expect(find.text(l.serverUnreachableTitle), findsOneWidget);
      expect(find.widgetWithText(FilledButton, l.retry), findsOneWidget);
      expect(find.text(l.selectOrCreateThreadToChat), findsNothing);
    });

    testWidgets('retry reconnects and loads the user', (tester) async {
      var down = true;
      final state = AppState.test(
        api: ApiService(client: _flakyClient(down: () => down)),
        connectionStatus: ConnectionStatus.disconnected,
      );
      addTearDown(state.dispose);

      await tester.pumpWidget(_buildWithState(state));
      await tester.pumpAndSettle();

      down = false;
      await tester.tap(find.widgetWithText(FilledButton, l.retry));
      await tester.pumpAndSettle();

      expect(state.connectionStatus, ConnectionStatus.connected);
      expect(state.user?.username, 'owner');
      expect(find.text(l.serverUnreachableTitle), findsNothing);
      // The deferred load started the health-check and git-refresh loops;
      // stop them so no periodic timer outlives the widget tree.
      state.stopHealthChecks();
      state.stopGitRefresh();
    });
  });
}
