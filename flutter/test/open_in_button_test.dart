import 'package:devinorium_frontend/services/editor_launcher.dart';
import 'package:devinorium_frontend/widgets/open_in_button.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeLauncher implements EditorLauncher {
  _FakeLauncher({this.supported = true, this.editors = const []});

  final bool supported;
  final List<EditorApp> editors;
  final List<({String path, String editorId})> opened = [];
  bool openResult = true;

  @override
  bool get isSupported => supported;

  @override
  Future<List<EditorApp>> detectEditors() async => editors;

  @override
  Future<bool> open(String path, String editorId) async {
    opened.add((path: path, editorId: editorId));
    return openResult;
  }
}

const _vscode = EditorApp(id: 'vscode', label: 'VS Code', commands: ['code']);
const _zed = EditorApp(id: 'zed', label: 'Zed', commands: ['zed']);
const _files = EditorApp(
  id: 'file-manager',
  label: 'File Manager',
  isFileManager: true,
);

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('is hidden when the launcher is unsupported', (tester) async {
    final launcher = _FakeLauncher(supported: false, editors: [_vscode]);
    await tester.pumpWidget(
      _wrap(OpenInButton(path: '/repo', launcher: launcher)),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('open_in_primary')), findsNothing);
    expect(find.byKey(const Key('open_in_menu')), findsNothing);
  });

  testWidgets('is hidden when no editors are detected', (tester) async {
    final launcher = _FakeLauncher();
    await tester.pumpWidget(
      _wrap(OpenInButton(path: '/repo', launcher: launcher)),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('open_in_primary')), findsNothing);
  });

  testWidgets('primary button opens the first detected editor', (tester) async {
    final launcher = _FakeLauncher(editors: [_vscode, _zed, _files]);
    await tester.pumpWidget(
      _wrap(OpenInButton(path: '/repo', launcher: launcher)),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('open_in_primary')), findsOneWidget);
    await tester.tap(find.byKey(const Key('open_in_primary')));
    await tester.pumpAndSettle();
    expect(launcher.opened.single, (path: '/repo', editorId: 'vscode'));
  });

  testWidgets('the menu lists editors and picks a new preferred one', (
    tester,
  ) async {
    final launcher = _FakeLauncher(editors: [_vscode, _zed, _files]);
    await tester.pumpWidget(
      _wrap(OpenInButton(path: '/repo', launcher: launcher)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('open_in_menu')));
    await tester.pumpAndSettle();
    expect(find.text('VS Code'), findsOneWidget);
    expect(find.text('Zed'), findsOneWidget);
    expect(find.text('File Manager'), findsOneWidget);

    await tester.tap(find.text('Zed'));
    await tester.pumpAndSettle();
    expect(launcher.opened.single, (path: '/repo', editorId: 'zed'));

    // The choice is persisted and becomes the new primary action.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('devinorium_preferred_editor'), 'zed');
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('open_in_primary')))
          .tooltip,
      'Open in Zed',
    );
  });

  testWidgets('a stored preference wins over catalog order', (tester) async {
    SharedPreferences.setMockInitialValues({
      'devinorium_preferred_editor': 'zed',
    });
    final launcher = _FakeLauncher(editors: [_vscode, _zed]);
    await tester.pumpWidget(
      _wrap(OpenInButton(path: '/repo', launcher: launcher)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('open_in_primary')));
    await tester.pumpAndSettle();
    expect(launcher.opened.single, (path: '/repo', editorId: 'zed'));
  });

  testWidgets('a stale stored preference falls back to VS Code', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'devinorium_preferred_editor': 'uninstalled',
    });
    final launcher = _FakeLauncher(editors: [_zed, _vscode]);
    await tester.pumpWidget(
      _wrap(OpenInButton(path: '/repo', launcher: launcher)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('open_in_primary')));
    await tester.pumpAndSettle();
    expect(launcher.opened.single, (path: '/repo', editorId: 'vscode'));
  });

  testWidgets('labels the file manager with the platform name', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final launcher = _FakeLauncher(editors: [_files]);
    await tester.pumpWidget(
      _wrap(OpenInButton(path: '/repo', launcher: launcher)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('open_in_menu')));
    await tester.pumpAndSettle();
    expect(find.text('Finder'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('a failed launch shows a snackbar', (tester) async {
    final launcher = _FakeLauncher(editors: [_vscode])..openResult = false;
    await tester.pumpWidget(
      _wrap(OpenInButton(path: '/repo', launcher: launcher)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('open_in_primary')));
    await tester.pumpAndSettle();
    expect(find.text('Could not open in VS Code'), findsOneWidget);
  });
}
