import 'dart:io';

import 'package:devinorium_frontend/services/multi_window_io.dart';
import 'package:devinorium_frontend/services/multi_window_types.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:devinorium_frontend/theme/theme.dart';
import 'package:devinorium_frontend/views/settings/topics.dart';
import 'package:devinorium_frontend/views/settings_page.dart';
import 'package:devinorium_frontend/generated/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeMultiWindow implements MultiWindowStore {
  bool stored = false;
  bool supported = true;
  bool throwOnLoad = false;
  bool throwOnSet = false;
  final sets = <bool>[];

  @override
  bool get isSupported => supported;

  @override
  Future<bool> load() async {
    if (throwOnLoad) throw StateError('load failed');
    return stored;
  }

  @override
  Future<void> setEnabled(bool enabled) async {
    sets.add(enabled);
    if (throwOnSet) throw StateError('write failed');
    stored = enabled;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('MultiWindowPreference', () {
    test('marker file name matches what the runners check', () {
      expect(MultiWindowStore.markerFileName, 'multi_window');
    });

    test('checkSupported only matches platforms with a runner check', () {
      expect(MultiWindowPreference.checkSupported('linux'), isTrue);
      expect(MultiWindowPreference.checkSupported('windows'), isTrue);
      expect(MultiWindowPreference.checkSupported('macos'), isFalse);
      expect(MultiWindowPreference.checkSupported('android'), isFalse);
      expect(MultiWindowPreference.checkSupported('ios'), isFalse);
    });

    test('load reports the marker file presence', () async {
      final dir = Directory.systemTemp.createTempSync('multi_window_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final pref = MultiWindowPreference(
        operatingSystem: 'linux',
        environment: const {},
        dataDir: dir.path,
      );
      expect(pref.isSupported, isTrue);
      expect(await pref.load(), isFalse);
    });

    test('setEnabled creates and removes the marker file', () async {
      final dir = Directory.systemTemp.createTempSync('multi_window_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final marker = File('${dir.path}/${MultiWindowStore.markerFileName}');
      final pref = MultiWindowPreference(
        operatingSystem: 'linux',
        environment: const {},
        dataDir: dir.path,
      );

      await pref.setEnabled(true);
      expect(marker.existsSync(), isTrue);
      expect(await pref.load(), isTrue);

      await pref.setEnabled(false);
      expect(marker.existsSync(), isFalse);
      expect(await pref.load(), isFalse);

      // Disabling an absent marker is a no-op, not an error.
      await pref.setEnabled(false);
      expect(marker.existsSync(), isFalse);
    });

    test('setEnabled creates the data directory when missing', () async {
      final dir = Directory.systemTemp.createTempSync('multi_window_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final nested = '${dir.path}/a/b';
      final pref = MultiWindowPreference(
        operatingSystem: 'windows',
        environment: const {},
        dataDir: nested,
      );

      await pref.setEnabled(true);
      expect(
        File('$nested/${MultiWindowStore.markerFileName}').existsSync(),
        isTrue,
      );
    });

    test('marker defaults to the shared per-user data directory', () async {
      final dir = Directory.systemTemp.createTempSync('multi_window_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final pref = MultiWindowPreference(
        operatingSystem: 'linux',
        environment: {'XDG_DATA_HOME': dir.path},
      );

      await pref.setEnabled(true);
      expect(
        File(
          '${dir.path}/devinorium/${MultiWindowStore.markerFileName}',
        ).existsSync(),
        isTrue,
      );
    });

    test('a directory named multi_window counts as disabled', () async {
      final dir = Directory.systemTemp.createTempSync('multi_window_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      Directory('${dir.path}/${MultiWindowStore.markerFileName}').createSync();
      final pref = MultiWindowPreference(
        operatingSystem: 'linux',
        environment: const {},
        dataDir: dir.path,
      );

      // The runners only accept a regular file, so a directory must not
      // report enabled here either.
      expect(await pref.load(), isFalse);
    });

    test('unsupported platforms never touch the filesystem', () async {
      final dir = Directory.systemTemp.createTempSync('multi_window_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final pref = MultiWindowPreference(
        operatingSystem: 'macos',
        environment: const {},
        dataDir: dir.path,
      );

      expect(pref.isSupported, isFalse);
      await pref.setEnabled(true);
      expect(dir.listSync(), isEmpty);
      expect(await pref.load(), isFalse);
    });
  });

  group('SettingsStore multi-window', () {
    test('setMultiWindowEnabled persists through the store', () async {
      final fake = _FakeMultiWindow();
      final state = AppState.test(multiWindow: fake);
      addTearDown(state.dispose);
      expect(state.multiWindowEnabled, isFalse);
      expect(state.multiWindowSupported, isTrue);

      await state.setMultiWindowEnabled(true);
      expect(state.multiWindowEnabled, isTrue);
      expect(fake.sets, [true]);

      await state.setMultiWindowEnabled(false);
      expect(state.multiWindowEnabled, isFalse);
      expect(fake.sets, [true, false]);
    });

    test('multiWindowSupported mirrors the store', () {
      final state = AppState.test(
        multiWindow: _FakeMultiWindow()..supported = false,
      );
      addTearDown(state.dispose);
      expect(state.multiWindowSupported, isFalse);
    });

    test('bootstrap loads the persisted marker state', () async {
      final fake = _FakeMultiWindow()..stored = true;
      final state = AppState.test(multiWindow: fake);
      addTearDown(state.dispose);

      await state.bootstrap();
      expect(state.multiWindowEnabled, isTrue);
    });

    test('a failing load reports disabled', () async {
      final fake = _FakeMultiWindow()
        ..stored = true
        ..throwOnLoad = true;
      final state = AppState.test(multiWindow: fake);
      addTearDown(state.dispose);

      await state.bootstrap();
      expect(state.multiWindowEnabled, isFalse);
    });

    test('a failing write leaves the previous state untouched', () async {
      final fake = _FakeMultiWindow()..throwOnSet = true;
      final state = AppState.test(multiWindow: fake);
      addTearDown(state.dispose);

      await state.setMultiWindowEnabled(true);
      expect(fake.sets, [true]);
      expect(state.multiWindowEnabled, isFalse);
    });

    test('setMultiWindowEnabled is a no-op on unsupported platforms', () async {
      final fake = _FakeMultiWindow()..supported = false;
      final state = AppState.test(multiWindow: fake);
      addTearDown(state.dispose);

      await state.setMultiWindowEnabled(true);
      expect(fake.sets, isEmpty);
      expect(state.multiWindowEnabled, isFalse);
    });
  });

  group('Personalization multi-window tile', () {
    Widget buildWithState(AppState state) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: state.locale,
      home: MultiProvider(
        providers: [
          ChangeNotifierProvider<AppState>.value(value: state),
          ChangeNotifierProvider<ThemeProvider>(
            create: (_) => ThemeProvider()..loadInitial(),
          ),
        ],
        child: const SettingsPage(),
      ),
    );

    int personalizationIndex() =>
        settingsTopicOrder(false).indexOf(SettingsTopic.personalization);

    testWidgets('toggle persists through the store', (tester) async {
      final fake = _FakeMultiWindow();
      final state = AppState.test(multiWindow: fake);
      addTearDown(state.dispose);

      await tester.pumpWidget(buildWithState(state));
      await tester.pumpAndSettle();
      state.setSettingsTopicIndex(personalizationIndex());
      await tester.pumpAndSettle();

      final tile = find.widgetWithText(SwitchListTile, 'Multiple windows');
      expect(tile, findsOneWidget);

      await tester.tap(tile);
      await tester.pumpAndSettle();
      expect(fake.sets, [true]);
      expect(state.multiWindowEnabled, isTrue);
    });

    testWidgets('toggle is hidden when the platform has no check to skip', (
      tester,
    ) async {
      final fake = _FakeMultiWindow()..supported = false;
      final state = AppState.test(multiWindow: fake);
      addTearDown(state.dispose);

      await tester.pumpWidget(buildWithState(state));
      await tester.pumpAndSettle();
      state.setSettingsTopicIndex(personalizationIndex());
      await tester.pumpAndSettle();

      expect(find.text('Multiple windows'), findsNothing);
    });
  });
}
