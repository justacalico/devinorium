import 'package:devinorium_frontend/main.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:devinorium_frontend/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _TrackingAppState extends AppState {
  var resumed = 0;

  @override
  void handleAppResumed() {
    resumed++;
  }
}

void main() {
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
