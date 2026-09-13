import 'dart:async';

import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/api/api_service.dart';
import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:devinorium_frontend/views/app_view.dart';
import 'package:devinorium_frontend/views/files_panel.dart';
import 'package:devinorium_frontend/views/sidebar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _ThrowingClient extends BaseApiClient {
  @override
  Future<bool> get isConfigured => Future.value(true);
  @override
  Future<void> clearCredentials() => Future.value();
  @override
  Future<void> init() => Future.value();
  @override
  bool get isNative => true;
  @override
  Future<String?> get serverUrl => Future.value(null);
  @override
  Future<String?> get token => Future.value(null);
  @override
  Future<void> setServerUrl(String serverUrl) => Future.value();
  @override
  Future<void> setToken(String token) => Future.value();
  @override
  Future<void> setUsername(String username) => Future.value();
  @override
  Future<Map<String, dynamic>> get(String path) => throw UnimplementedError();
  @override
  Future<List<Map<String, dynamic>>> getList(String path) =>
      throw UnimplementedError();
  @override
  Stream<SseEvent> getStream({required String path}) =>
      throw UnimplementedError();
  @override
  Stream<SseEvent> postStream({
    required String path,
    Map<String, String> fields = const {},
    List<({String filename, String mime, Uint8List bytes})> attachments =
        const [],
  }) => throw UnimplementedError();
  @override
  Future<Map<String, dynamic>> post(String path, [Object? body]) =>
      throw UnimplementedError();
  @override
  Future<Map<String, dynamic>> put(String path, [Object? body]) =>
      throw UnimplementedError();
  @override
  Future<Map<String, dynamic>> patch(String path, [Object? body]) =>
      throw UnimplementedError();
  @override
  Future<Map<String, dynamic>> delete(String path) =>
      throw UnimplementedError();
  @override
  Future<Map<String, dynamic>> deleteWithBody(String path, Object body) =>
      throw UnimplementedError();
  @override
  Future<Map<String, dynamic>> uploadMultipart(
    String path,
    Map<String, String> fields,
    List<({String filename, String mime, Uint8List bytes})> files,
  ) => throw UnimplementedError();
  @override
  Stream<SseEvent> sendStream({
    required String path,
    required String prompt,
    String? mode,
    String? clientMessageId,
    List<({String filename, String mime, Uint8List bytes})> attachments =
        const [],
    List<PathRef> contextPaths = const [],
    List<String> referencedThreadIds = const [],
  }) => throw UnimplementedError();
}

ApiService _api() => ApiService(client: _ThrowingClient());

AppState _state({bool sidebarCompact = false}) => AppState.test(
  api: _api(),
  sidebarCompact: sidebarCompact,
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

Widget _shell(AppState state, {Size size = const Size(1200, 800)}) {
  return MaterialApp(
    theme: ThemeData(platform: TargetPlatform.linux, useMaterial3: true),
    home: ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MediaQuery(
        data: MediaQueryData(size: size),
        child: const AppShell(),
      ),
    ),
  );
}

Widget _sidebarAt(AppState state, double width) {
  return MaterialApp(
    theme: ThemeData(platform: TargetPlatform.linux, useMaterial3: true),
    home: ChangeNotifierProvider<AppState>.value(
      value: state,
      child: Scaffold(
        body: SizedBox(width: width, child: const Sidebar()),
      ),
    ),
  );
}

Size _sidebarSize(WidgetTester tester) => tester.getSize(find.byType(Sidebar));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    PackageInfo.setMockInitialValues(
      appName: 'Devinorium',
      packageName: 'devinorium_frontend',
      version: '0.21.0',
      buildNumber: '25',
      buildSignature: '',
    );
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('compact preference', () {
    test('setSidebarCompact toggles, notifies, and persists', () async {
      final state = AppState.test();
      addTearDown(state.dispose);

      var calls = 0;
      state.addListener(() => calls++);

      state.setSidebarCompact(true);
      expect(state.sidebarCompact, isTrue);

      state.setSidebarCompact(false);
      expect(state.sidebarCompact, isFalse);
      expect(calls, 2);

      await Future<void>.delayed(Duration.zero);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('devinorium_sidebar_compact'), isFalse);
    });

    test('window auto-collapse combines with the stored preference', () async {
      final state = AppState.test();
      addTearDown(state.dispose);

      state.setSidebarCompactAuto(true);
      expect(state.sidebarCompact, isTrue);

      // Auto-collapse alone never touches the stored preference.
      await Future<void>.delayed(Duration.zero);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('devinorium_sidebar_compact'), isNull);

      // Toggling while auto-collapsed expands and clears the auto flag.
      state.toggleSidebarCompact();
      expect(state.sidebarCompact, isFalse);

      // While expanded, the auto-collapse can take over again.
      state.setSidebarCompactAuto(true);
      expect(state.sidebarCompact, isTrue);
    });

    test('toggleSidebarCompact flips the effective state', () {
      final state = AppState.test();
      addTearDown(state.dispose);

      state.toggleSidebarCompact();
      expect(state.sidebarCompact, isTrue);
      state.toggleSidebarCompact();
      expect(state.sidebarCompact, isFalse);
    });

    test(
      'opening the files or git panel expands without touching the pref',
      () async {
        final state = AppState.test(api: _api());
        addTearDown(state.dispose);

        // Persist the user's choice first, as a real session would.
        state.setSidebarCompact(true);
        await Future<void>.delayed(Duration.zero);
        var prefs = await SharedPreferences.getInstance();
        expect(prefs.getBool('devinorium_sidebar_compact'), isTrue);

        await state.openFilesPanel();
        expect(state.sidebarCompact, isFalse);

        // A programmatic expand is transient: the stored pref stays intact.
        await Future<void>.delayed(Duration.zero);
        prefs = await SharedPreferences.getInstance();
        expect(prefs.getBool('devinorium_sidebar_compact'), isTrue);

        state.setSidebarCompact(true);
        await state.openGitPanel();
        expect(state.sidebarCompact, isFalse);
      },
    );

    test('switching to editor mode expands the sidebar', () {
      final state = AppState.test(sidebarCompact: true);
      addTearDown(state.dispose);

      state.setAppMode(AppMode.editor);
      expect(state.sidebarCompact, isFalse);
    });

    test('collapsing is refused in editor mode', () {
      final state = AppState.test();
      addTearDown(state.dispose);

      state.setAppMode(AppMode.editor);
      state.setSidebarCompact(true);
      expect(state.sidebarCompact, isFalse);

      state.toggleSidebarCompact();
      expect(state.sidebarCompact, isFalse);
    });

    test('collapsing closes the files and git panels', () async {
      final state = AppState.test(api: _api());
      addTearDown(state.dispose);

      await state.openFilesPanel();
      expect(state.filesPanelOpen, isTrue);

      state.setSidebarCompact(true);
      expect(state.sidebarCompact, isTrue);
      expect(state.filesPanelOpen, isFalse);
    });

    test('auto-collapse stays pending while a side panel is open', () async {
      final state = AppState.test(api: _api());
      addTearDown(state.dispose);

      await state.openFilesPanel();
      state.setSidebarCompactAuto(true);
      // The open panel suppresses the rail.
      expect(state.sidebarCompact, isFalse);

      // Closing the panel lets the pending auto-collapse apply.
      state.closeFilesPanel();
      expect(state.sidebarCompact, isTrue);
    });
  });

  group('compact rail layout', () {
    testWidgets('compact preference renders the rail instead of the list', (
      tester,
    ) async {
      final state = _state(sidebarCompact: true);
      addTearDown(state.dispose);
      await tester.pumpWidget(_shell(state));
      await tester.pumpAndSettle();

      expect(_sidebarSize(tester).width, 64);
      expect(find.text('My thread'), findsNothing);
      expect(find.byKey(const Key('rail_project_1')), findsOneWidget);
      expect(find.byKey(const Key('sidebar_compact_toggle')), findsOneWidget);
    });

    testWidgets('toggle button expands the rail and collapses it back', (
      tester,
    ) async {
      final state = _state(sidebarCompact: true);
      addTearDown(state.dispose);
      await tester.pumpWidget(_shell(state));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('sidebar_compact_toggle')));
      await tester.pumpAndSettle();

      expect(state.sidebarCompact, isFalse);
      expect(_sidebarSize(tester).width, greaterThan(200));
      expect(find.text('My thread'), findsOneWidget);

      await tester.tap(find.byKey(const Key('sidebar_compact_toggle')));
      await tester.pumpAndSettle();

      expect(state.sidebarCompact, isTrue);
      expect(_sidebarSize(tester).width, 64);
      expect(find.text('My thread'), findsNothing);
    });

    testWidgets('Ctrl+B toggles the rail on wide layouts', (tester) async {
      final state = _state();
      addTearDown(state.dispose);
      await tester.pumpWidget(_shell(state));
      await tester.pumpAndSettle();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyB);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyB);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      expect(state.sidebarCompact, isTrue);
      expect(_sidebarSize(tester).width, 64);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyB);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyB);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      expect(state.sidebarCompact, isFalse);
    });

    testWidgets('Ctrl+B does nothing on narrow layouts', (tester) async {
      final state = _state();
      addTearDown(state.dispose);
      await tester.pumpWidget(_shell(state, size: const Size(600, 800)));
      await tester.pumpAndSettle();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyB);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyB);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      expect(state.sidebarCompact, isFalse);
    });

    testWidgets('narrow overlay keeps the full sidebar when compact', (
      tester,
    ) async {
      final state = _state(sidebarCompact: true);
      addTearDown(state.dispose);
      await tester.pumpWidget(_shell(state, size: const Size(600, 800)));
      await tester.pumpAndSettle();

      state.openSidebar();
      await tester.pumpAndSettle();

      // The slide-over is wide enough that the regular sidebar renders.
      expect(_sidebarSize(tester).width, greaterThan(160));
      expect(find.text('My thread'), findsOneWidget);
      expect(find.byKey(const Key('sidebar_compact_toggle')), findsNothing);
    });

    testWidgets('very narrow window auto-collapses and recovers', (
      tester,
    ) async {
      final state = _state();
      addTearDown(state.dispose);
      await tester.pumpWidget(_shell(state, size: const Size(800, 800)));
      await tester.pumpAndSettle();

      expect(state.sidebarCompact, isTrue);
      expect(_sidebarSize(tester).width, 64);

      await tester.pumpWidget(_shell(state, size: const Size(1200, 800)));
      await tester.pumpAndSettle();

      // The auto-collapse lifts again; the stored preference was never set.
      expect(state.sidebarCompact, isFalse);
      expect(_sidebarSize(tester).width, greaterThan(200));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('devinorium_sidebar_compact'), isNull);
    });

    testWidgets('resizing below the threshold collapses into the rail', (
      tester,
    ) async {
      final state = _state();
      addTearDown(state.dispose);
      await tester.pumpWidget(_shell(state));
      await tester.pumpAndSettle();

      await tester.drag(
        find.byKey(const Key('sidebar_resize_handle')),
        const Offset(-140, 0),
      );
      await tester.pumpAndSettle();

      expect(state.sidebarCompact, isTrue);
      expect(_sidebarSize(tester).width, 64);

      // A small pull past the touch slop stays below the expand threshold.
      await tester.drag(
        find.byKey(const Key('sidebar_resize_handle')),
        const Offset(30, 0),
      );
      await tester.pumpAndSettle();
      expect(state.sidebarCompact, isTrue);

      // Pulling right from the rail restores the pre-drag width.
      await tester.drag(
        find.byKey(const Key('sidebar_resize_handle')),
        const Offset(60, 0),
      );
      await tester.pumpAndSettle();

      expect(state.sidebarCompact, isFalse);
      expect(_sidebarSize(tester).width, 300);
    });

    testWidgets('double tapping the resize handle toggles the rail', (
      tester,
    ) async {
      final state = _state();
      addTearDown(state.dispose);
      await tester.pumpWidget(_shell(state));
      await tester.pumpAndSettle();

      final handle = find.byKey(const Key('sidebar_resize_handle'));
      await tester.tap(handle);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(handle);
      await tester.pumpAndSettle();

      expect(state.sidebarCompact, isTrue);
    });
  });

  group('compact rail contents', () {
    testWidgets('project icon opens a flyout with its threads', (tester) async {
      final state = _state(sidebarCompact: true);
      addTearDown(state.dispose);
      await tester.pumpWidget(_sidebarAt(state, 64));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('rail_project_1')));
      await tester.pumpAndSettle();

      expect(find.text('My thread'), findsOneWidget);
      expect(find.text('New thread in p'), findsOneWidget);

      await tester.tap(find.text('My thread'));
      await tester.pumpAndSettle();
      expect(state.activeThreadId, 'a');
    });

    testWidgets('search icon expands the sidebar and focuses the field', (
      tester,
    ) async {
      final state = _state(sidebarCompact: true);
      addTearDown(state.dispose);
      await tester.pumpWidget(_shell(state));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('rail_search')));
      await tester.pumpAndSettle();

      expect(state.sidebarCompact, isFalse);
      final field = tester.widget<EditableText>(
        find.descendant(
          of: find.byKey(const Key('sidebar_search')),
          matching: find.byType(EditableText),
        ),
      );
      expect(field.focusNode.hasFocus, isTrue);
    });

    testWidgets('files icon expands and opens the files panel', (tester) async {
      final state = _state(sidebarCompact: true);
      addTearDown(state.dispose);
      await tester.pumpWidget(_shell(state));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Files'));
      await tester.pumpAndSettle();

      expect(state.filesPanelOpen, isTrue);
      expect(state.sidebarCompact, isFalse);
      expect(
        find.descendant(
          of: find.byType(Sidebar),
          matching: find.byType(FilesPanel),
        ),
        findsOneWidget,
      );
    });

    testWidgets('settings page keeps icon navigation in the rail', (
      tester,
    ) async {
      final state = _state(sidebarCompact: true);
      addTearDown(state.dispose);
      state.setPage(MainPage.settings);
      await tester.pumpWidget(_sidebarAt(state, 64));
      await tester.pumpAndSettle();

      expect(find.byTooltip('Account'), findsOneWidget);
      expect(find.byTooltip('Providers'), findsOneWidget);

      await tester.tap(find.byTooltip('Personalization'));
      await tester.pumpAndSettle();
      expect(state.settingsTopicIndex, 2);
    });

    testWidgets('project flyout offers options and load-more entries', (
      tester,
    ) async {
      final state = _state(sidebarCompact: true);
      addTearDown(state.dispose);
      await tester.pumpWidget(_sidebarAt(state, 64));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('rail_project_1')));
      await tester.pumpAndSettle();

      // The same management actions the expanded options menu exposes.
      expect(find.text('Options'), findsOneWidget);
    });

    testWidgets('running badge appears when the running set changes', (
      tester,
    ) async {
      final state = _state(sidebarCompact: true);
      addTearDown(state.dispose);
      await tester.pumpWidget(_sidebarAt(state, 64));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('rail_running_1')), findsNothing);

      state.setRunningThreadIds({'a'});
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('rail_running_1')), findsOneWidget);
    });

    testWidgets('user avatar opens the user menu', (tester) async {
      final state = _state(sidebarCompact: true);
      addTearDown(state.dispose);
      await tester.pumpWidget(_sidebarAt(state, 64));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('rail_user_menu')));
      await tester.pumpAndSettle();

      expect(find.text('Settings'), findsWidgets);
      expect(find.text('Sign out'), findsOneWidget);
    });

    testWidgets('Ctrl+H in the rail expands and focuses search', (
      tester,
    ) async {
      final state = _state(sidebarCompact: true);
      addTearDown(state.dispose);
      await tester.pumpWidget(_shell(state));
      await tester.pumpAndSettle();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyH);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyH);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      expect(state.sidebarCompact, isFalse);
      final field = tester.widget<EditableText>(
        find.descendant(
          of: find.byKey(const Key('sidebar_search')),
          matching: find.byType(EditableText),
        ),
      );
      expect(field.focusNode.hasFocus, isTrue);
    });
  });
}
