import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:devinorium_frontend/views/app_view.dart';
import 'package:devinorium_frontend/views/files_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

Widget _buildWithState(
  AppState state, {
  Size size = const Size(1200, 800),
  TargetPlatform platform = TargetPlatform.iOS,
}) {
  return MaterialApp(
    theme: ThemeData(platform: platform, useMaterial3: true),
    home: ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MediaQuery(
        data: MediaQueryData(size: size),
        child: const AppShell(),
      ),
    ),
  );
}

AppState _baseState() => AppState.test(
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

void main() {
  group('AppShell files panel on narrow screens', () {
    testWidgets('openFilesPanel opens end drawer on narrow screens',
        (tester) async {
      tester.view.physicalSize = const Size(600, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final state = _baseState();
      await tester.pumpWidget(_buildWithState(state, size: const Size(600, 800)));
      await tester.pumpAndSettle();

      // No files panel visible initially.
      expect(find.byType(Drawer), findsNothing);

      // Open the files panel.
      state.openFilesPanel();
      await tester.pumpAndSettle();

      // The end drawer should be open with the FilesPanel.
      expect(find.byType(FilesPanel), findsOneWidget);
    });

    testWidgets('closing the end drawer sets filesPanelOpen to false',
        (tester) async {
      tester.view.physicalSize = const Size(600, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final state = _baseState();
      await tester.pumpWidget(_buildWithState(state, size: const Size(600, 800)));
      await tester.pumpAndSettle();

      state.openFilesPanel();
      await tester.pumpAndSettle();

      expect(state.filesPanelOpen, isTrue);

      // Close the drawer by tapping outside (scrim).
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      expect(state.filesPanelOpen, isFalse);
    });

    testWidgets('files panel shows inline on wide screens', (tester) async {
      final state = _baseState();
      await tester.pumpWidget(_buildWithState(state, size: const Size(1200, 800)));
      await tester.pumpAndSettle();

      // Open the files panel — should show inline, not as a drawer.
      state.openFilesPanel();
      await tester.pumpAndSettle();

      expect(find.byType(FilesPanel), findsOneWidget);
      // On wide screens there should be no Drawer widget for the files panel.
      expect(find.byType(Drawer), findsNothing);
    });
  });

  group('AppShell resize preserves state', () {
    testWidgets('composer text survives narrow <-> wide layout switch',
        (tester) async {
      final state = _baseState();
      await tester.pumpWidget(
        _buildWithState(state, size: const Size(1200, 800)),
      );
      await tester.pumpAndSettle();

      // Type into the composer.
      await tester.enterText(find.byType(TextField), 'hello world');
      await tester.pumpAndSettle();
      expect(find.text('hello world'), findsOneWidget);

      // Shrink to phone width — the layout swaps from Row to drawer mode.
      await tester.pumpWidget(
        _buildWithState(state, size: const Size(400, 800)),
      );
      await tester.pumpAndSettle();

      // The composer text must still be there.
      expect(find.text('hello world'), findsOneWidget);

      // Grow back to wide and confirm it is still intact.
      await tester.pumpWidget(
        _buildWithState(state, size: const Size(1200, 800)),
      );
      await tester.pumpAndSettle();

      expect(find.text('hello world'), findsOneWidget);
    });
  });
}
