import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/api/api_service.dart';
import 'package:devinorium_frontend/issue/issue_models.dart';
import 'package:devinorium_frontend/issue/issue_provider.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:devinorium_frontend/state/async_value.dart';
import 'package:devinorium_frontend/views/issue_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

class _FakeIssueProvider extends IssueProvider {
  bool disposedFlag = false;
  int loadCalls = 0;

  @override
  AsyncValue<IssueDetail> get value => const AsyncValue.loading();

  @override
  bool canHandle(String url) => true;

  @override
  Future<void> load(String url) async {
    loadCalls++;
  }

  @override
  void dispose() {
    disposedFlag = true;
    super.dispose();
  }
}

void main() {
  testWidgets('IssuePanel does not dispose an injected provider', (
    tester,
  ) async {
    final provider = _FakeIssueProvider();
    final state = AppState.test(
      api: ApiService(
        client: ApiClient.withClient(
          MockClient((_) async => throw UnimplementedError()),
        ),
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: ChangeNotifierProvider<AppState>.value(
          value: state,
          child: IssuePanel(
            url: 'https://gitlab.com/g/p/-/issues/1',
            provider: provider,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(provider.loadCalls, 1);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(provider.disposedFlag, isFalse);
  });

  testWidgets('IssuePanel swaps an injected provider without disposing it', (
    tester,
  ) async {
    final first = _FakeIssueProvider();
    final second = _FakeIssueProvider();
    final state = AppState.test(
      api: ApiService(
        client: ApiClient.withClient(
          MockClient((_) async => throw UnimplementedError()),
        ),
      ),
    );

    Widget build(IssueProvider provider) => MaterialApp(
      home: ChangeNotifierProvider<AppState>.value(
        value: state,
        child: IssuePanel(
          url: 'https://gitlab.com/g/p/-/issues/1',
          provider: provider,
        ),
      ),
    );

    await tester.pumpWidget(build(first));
    await tester.pump();
    expect(first.loadCalls, 1);

    await tester.pumpWidget(build(second));
    await tester.pump();

    expect(first.disposedFlag, isFalse);
    expect(second.loadCalls, 1);
  });
}
