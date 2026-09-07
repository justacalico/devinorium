import 'package:devinorium_frontend/main.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:devinorium_frontend/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _TrackingAppState extends AppState {
  var resumed = 0;

  @override
  void handleAppResumed() {
    resumed++;
  }
}

void main() {
  testWidgets('RootScaffold insets content within the system safe area', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'Devinorium',
      packageName: 'devinorium_frontend',
      version: '0.21.0',
      buildNumber: '25',
      buildSignature: '',
    );

    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    tester.view.padding = const FakeViewPadding(top: 48, bottom: 32);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final appState = AppState();
    final themeProvider = ThemeProvider();
    await themeProvider.loadInitial();
    addTearDown(appState.dispose);
    addTearDown(themeProvider.dispose);
    addTearDown(() async {
      await tester.pumpWidget(Container());
    });

    await tester.pumpWidget(
      DevinoriumApp(appState: appState, themeProvider: themeProvider),
    );
    await tester.pump();

    final loadingBox = tester.getRect(find.byType(Scaffold));
    expect(loadingBox.top, 48.0);
    expect(loadingBox.bottom, 768.0);

    appState.setView(AppView.app);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final appShellBox = tester.getRect(find.byType(Scaffold).first);
    expect(appShellBox.top, 48.0);
    expect(appShellBox.bottom, 768.0);

    appState.setView(AppView.loading);
    await tester.pump();
    final resetBox = tester.getRect(find.byType(Scaffold));
    expect(resetBox.top, 48.0);
    expect(resetBox.bottom, 768.0);
  });

  testWidgets('resumed lifecycle state triggers handleAppResumed', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});

    final appState = _TrackingAppState();
    final themeProvider = ThemeProvider();
    await themeProvider.loadInitial();
    addTearDown(() async {
      await tester.pumpWidget(Container());
    });
    addTearDown(appState.dispose);
    addTearDown(
      () => tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      ),
    );

    await tester.pumpWidget(
      DevinoriumApp(appState: appState, themeProvider: themeProvider),
    );

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(appState.resumed, 0);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(appState.resumed, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(appState.resumed, 2);
  });
}
