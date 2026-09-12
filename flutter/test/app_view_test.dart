import 'dart:convert';

import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/api/api_service.dart';
import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:devinorium_frontend/views/app_view.dart';
import 'package:devinorium_frontend/views/files_panel.dart';
import 'package:devinorium_frontend/views/sidebar.dart';
import 'package:devinorium_frontend/views/window_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

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

AppState _baseState({ApiClient? api}) => AppState.test(
      api: api != null ? ApiService(client: api) : null,
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
  setUpAll(() {
    PackageInfo.setMockInitialValues(
      appName: 'Devinorium',
      packageName: 'devinorium_frontend',
      version: '0.21.0',
      buildNumber: '25',
      buildSignature: '',
    );
  });

  group('AppShell files view on narrow screens', () {
    testWidgets('openFilesPanel opens the sidebar drawer on narrow screens',
        (tester) async {
      tester.view.physicalSize = const Size(600, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final state = _baseState(api: _clientFor([_json(200, [])]));
      addTearDown(state.dispose);
      await tester.pumpWidget(_buildWithState(state, size: const Size(600, 800)));
      await tester.pumpAndSettle();

      // No files panel visible initially.
      expect(find.byType(Drawer), findsNothing);

      // Open the files view — the sidebar drawer shows it.
      await state.openFilesPanel();
      await tester.pumpAndSettle();

      expect(find.byType(FilesPanel), findsOneWidget);
    });

    testWidgets('closing the drawer switches the sidebar back to threads',
        (tester) async {
      tester.view.physicalSize = const Size(600, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final state = _baseState(api: _clientFor([_json(200, [])]));
      addTearDown(state.dispose);
      await tester.pumpWidget(_buildWithState(state, size: const Size(600, 800)));
      await tester.pumpAndSettle();

      await state.openFilesPanel();
      await tester.pumpAndSettle();

      expect(state.filesPanelOpen, isTrue);

      // Close the drawer by tapping outside (scrim).
      await tester.tapAt(const Offset(500, 400));
      await tester.pumpAndSettle();

      expect(state.filesPanelOpen, isFalse);
    });

    testWidgets('files view shows inside the sidebar on wide screens',
        (tester) async {
      final state = _baseState(api: _clientFor([_json(200, [])]));
      addTearDown(state.dispose);
      await tester.pumpWidget(_buildWithState(state, size: const Size(1200, 800)));
      await tester.pumpAndSettle();

      // The files view lives inside the sidebar, not as a separate panel.
      await state.openFilesPanel();
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byType(Sidebar),
          matching: find.byType(FilesPanel),
        ),
        findsOneWidget,
      );
      expect(find.byType(Drawer), findsNothing);
    });
  });

  group('AppShell sidebar overlay on narrow screens', () {
    testWidgets('menu state opens and closes the slide-over sidebar',
        (tester) async {
      tester.view.physicalSize = const Size(600, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final state = _baseState(api: _clientFor([_json(200, [])]));
      addTearDown(state.dispose);
      await tester.pumpWidget(_buildWithState(state, size: const Size(600, 800)));
      await tester.pumpAndSettle();

      expect(state.sidebarOpen, isFalse);
      expect(find.byType(Drawer), findsNothing);

      state.openSidebar();
      await tester.pumpAndSettle();
      expect(state.sidebarOpen, isTrue);

      // Tapping the scrim closes the overlay.
      await tester.tapAt(const Offset(500, 400));
      await tester.pumpAndSettle();
      expect(state.sidebarOpen, isFalse);
    });

    testWidgets(
        'thread dragged out of the sidebar overlay reaches the composer',
        (tester) async {
      tester.view.physicalSize = const Size(600, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final state = AppState.test(
        api: ApiService(client: _clientFor([_json(200, [])])),
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
            title: 'Active thread',
            projectId: 1,
            model: '',
            permissionMode: 'normal',
            createdAt: '',
            updatedAt: '',
          ),
          Thread(
            id: 'b',
            title: 'Other thread',
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
      addTearDown(state.dispose);
      await tester.pumpWidget(_buildWithState(state, size: const Size(600, 800)));
      await tester.pumpAndSettle();

      state.openSidebar();
      await tester.pumpAndSettle();

      final tile = find.text('Other thread');
      expect(tile, findsOneWidget);
      final tileCenter = tester.getCenter(tile);

      // A horizontal pull starts the drag; the overlay slides away while the
      // drag is still in progress so the composer becomes a valid target.
      final gesture = await tester.startGesture(tileCenter);
      await gesture.moveBy(const Offset(60, 0));
      await tester.pumpAndSettle();

      expect(state.sidebarOpen, isFalse);

      final composer = find.byKey(const Key('composer_input'));
      expect(composer, findsOneWidget);
      await gesture.moveTo(tester.getCenter(composer));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(
        state.threadReferences.any((ref) => ref.id == 'b'),
        isTrue,
      );
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
      await tester.enterText(find.byKey(const Key('composer_input')), 'hello world');
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

  group('AppShell title placement', () {
    testWidgets('app title and controls are in the sidebar', (tester) async {
      final state = _baseState();
      await tester.pumpWidget(
        _buildWithState(
          state,
          size: const Size(1200, 800),
          platform: TargetPlatform.linux,
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.descendant(of: find.byType(Sidebar), matching: find.text('Devinorium')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: find.byType(Sidebar), matching: find.text('0.21.0')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(Sidebar),
          matching: find.byType(WindowControls),
        ),
        findsOneWidget,
      );
    });
  });
}
