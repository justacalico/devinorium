import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:devinorium_frontend/views/sidebar.dart';
import 'package:devinorium_frontend/widgets/thread_tag.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _buildWithState(AppState state) => MaterialApp(
      home: ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const Scaffold(
          drawer: Drawer(child: Sidebar()),
          body: SizedBox.shrink(),
        ),
      ),
    );

Future<void> _openDrawer(WidgetTester tester) async {
  final scaffold = tester.state<ScaffoldState>(find.byType(Scaffold));
  scaffold.openDrawer();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Sidebar shows settings topics for owners', (tester) async {
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
    state.setPage(MainPage.settings);

    await tester.pumpWidget(_buildWithState(state));
    await _openDrawer(tester);

    expect(find.text('Account'), findsOneWidget);
    expect(find.text('Providers'), findsOneWidget);
    expect(find.text('Devices'), findsOneWidget);
    expect(find.text('Personalization'), findsOneWidget);
    expect(find.text('Manage'), findsOneWidget);
    expect(find.text('Owner'), findsOneWidget);
  });

  testWidgets('Sidebar hides Manage topic for non-owners', (tester) async {
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
    );
    state.setPage(MainPage.settings);

    await tester.pumpWidget(_buildWithState(state));
    await _openDrawer(tester);

    expect(find.text('Account'), findsOneWidget);
    expect(find.text('Providers'), findsOneWidget);
    expect(find.text('Devices'), findsOneWidget);
    expect(find.text('Personalization'), findsOneWidget);
    expect(find.text('Manage'), findsNothing);
  });

  testWidgets('Settings topic selection updates AppState', (tester) async {
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
    state.setPage(MainPage.settings);

    await tester.pumpWidget(_buildWithState(state));
    await _openDrawer(tester);

    await tester.tap(find.text('Personalization'));
    await tester.pumpAndSettle();

    expect(state.settingsTopicIndex, 3);
  });

  testWidgets('Sidebar thread tiles do not show status tags', (tester) async {
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
      projects: [
        Project(id: 1, name: 'p', path: '/x', createdAt: '', updatedAt: ''),
      ],
      threads: [
        Thread(
          id: 'a',
          title: 'My thread',
          projectId: 1,
          model: '',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '',
        ),
      ],
      activeProjectId: 1,
      activeThreadId: 'a',
    );

    await tester.pumpWidget(_buildWithState(state));
    await _openDrawer(tester);

    expect(find.text('My thread'), findsOneWidget);
    expect(find.byType(ThreadTag), findsNothing);
  });

  testWidgets('Projects start collapsed when no thread is active', (tester) async {
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
      projects: [
        Project(id: 1, name: 'p', path: '/x', createdAt: '', updatedAt: ''),
      ],
      threads: [
        Thread(
          id: 'a',
          title: 'My thread',
          projectId: 1,
          model: '',
          permissionMode: 'normal',
          createdAt: '',
          updatedAt: '',
        ),
      ],
      activeProjectId: 1,
    );

    await tester.pumpWidget(_buildWithState(state));
    await _openDrawer(tester);

    expect(find.text('My thread'), findsNothing);

    await tester.tap(find.text('p'));
    await tester.pumpAndSettle();

    expect(find.text('My thread'), findsOneWidget);
  });
}
