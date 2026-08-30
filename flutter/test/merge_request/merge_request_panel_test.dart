import 'dart:convert';

import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/api/api_service.dart';
import 'package:devinorium_frontend/merge_request/merge_request_models.dart';
import 'package:devinorium_frontend/merge_request/merge_request_provider.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:devinorium_frontend/state/async_value.dart';
import 'package:devinorium_frontend/views/merge_request_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart';
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

class _TestProvider extends MergeRequestProvider {
  int loadCalls = 0;
  bool disposed = false;

  @override
  AsyncValue<MergeRequestDetail> get value => const AsyncValue.loading();

  @override
  bool canHandle(String url) => true;

  @override
  Future<void> load(String url) async {
    loadCalls++;
  }

  @override
  Future<void> perform(MergeRequestAction action) async {}

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}

class _AlwaysLoadingProvider extends MergeRequestProvider {
  int loadCalls = 0;

  @override
  AsyncValue<MergeRequestDetail> get value =>
      const AsyncValue<MergeRequestDetail>.loading();

  @override
  bool canHandle(String url) => true;

  @override
  Future<void> load(String url) async {
    loadCalls++;
  }

  @override
  Future<void> perform(MergeRequestAction action) async {}
}

Response _json(int status, Object body) => Response(jsonEncode(body), status);

AppState _appState(MockClient client) =>
    AppState.test(api: ApiService(client: ApiClient.withClient(client)));

void main() {
  testWidgets('does not call load on an externally supplied provider', (
    tester,
  ) async {
    final provider = _TestProvider();
    final state = _appState(MockClient((_) async => _json(404, {})));

    await tester.pumpWidget(
      MaterialApp(
        home: ChangeNotifierProvider<AppState>.value(
          value: state,
          child: MergeRequestPanel(
            url: 'https://gitlab.com/group/project/-/merge_requests/1',
            provider: provider,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(provider.loadCalls, 0);
    expect(provider.disposed, isFalse);

    await tester.pumpWidget(Container());
    await tester.pumpAndSettle();

    expect(provider.disposed, isFalse);
  });

  testWidgets('creates its own GitLab provider and loads the merge request', (
    tester,
  ) async {
    final mock = MockClient((req) async {
      final proxy = req.url.queryParameters['path'] ?? '';
      final path = req.url.path;

      if (path == '/api/git-connections/gitlab/pipelines') {
        return _json(200, {'_list': []});
      }

      if (proxy.endsWith('/merge_requests/1')) {
        return _json(200, {
          'iid': 1,
          'title': 'Test MR',
          'state': 'opened',
          'source_branch': 'feature',
          'target_branch': 'main',
          'web_url': 'https://gitlab.com/group/project/-/merge_requests/1',
          'description': '',
        });
      }

      return _json(200, {'_list': []});
    });

    final state = _appState(mock);

    await tester.pumpWidget(
      MaterialApp(
        home: ChangeNotifierProvider<AppState>.value(
          value: state,
          child: const MergeRequestPanel(
            url: 'https://gitlab.com/group/project/-/merge_requests/1',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Test MR'), findsOneWidget);
  });

  testWidgets('disposes the provider it created', (tester) async {
    final mock = MockClient((_) async => _json(200, {'_list': []}));
    final state = _appState(mock);

    await tester.pumpWidget(
      MaterialApp(
        home: ChangeNotifierProvider<AppState>.value(
          value: state,
          child: const MergeRequestPanel(
            url: 'https://gitlab.com/group/project/-/merge_requests/1',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.pumpWidget(Container());
    await tester.pumpAndSettle();

    expect(find.byType(MergeRequestPanel), findsNothing);
  });

  testWidgets('does not rebuild after text scale changes', (tester) async {
    final provider = _AlwaysLoadingProvider();
    final state = _appState(MockClient((_) async => _json(404, {})));

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(1.0)),
        child: MaterialApp(
          home: ChangeNotifierProvider<AppState>.value(
            value: state,
            child: MergeRequestPanel(
              url: 'https://gitlab.com/group/project/-/merge_requests/1',
              provider: provider,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(1.2)),
        child: MaterialApp(
          home: ChangeNotifierProvider<AppState>.value(
            value: state,
            child: MergeRequestPanel(
              url: 'https://gitlab.com/group/project/-/merge_requests/1',
              provider: provider,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(provider.loadCalls, 0);
  });
}
