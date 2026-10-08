import 'package:devinorium_frontend/main.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:devinorium_frontend/state/zoom_controller.dart';
import 'package:devinorium_frontend/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
      DevinoriumApp(
        appState: appState,
        themeProvider: themeProvider,
        zoomController: ZoomController(),
      ),
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

  testWidgets(
    'RootScaffold fills the strips around the safe area with the scaffold color',
    (tester) async {
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
      final themeProvider = ThemeProvider(
        initialChoice: const BuiltInThemeChoice(BuiltInThemes.darkId),
      );
      addTearDown(appState.dispose);
      addTearDown(themeProvider.dispose);
      addTearDown(() async {
        await tester.pumpWidget(Container());
      });

      await tester.pumpWidget(
        DevinoriumApp(
          appState: appState,
          themeProvider: themeProvider,
          zoomController: ZoomController(),
        ),
      );
      await tester.pump();

      Finder backdrop(Color color) => find.ancestor(
        of: find.byType(SafeArea),
        matching: find.byWidgetPredicate(
          (widget) => widget is ColoredBox && widget.color == color,
        ),
      );

      final darkSurface = themeProvider.darkTheme.scaffoldBackgroundColor;

      final darkBackdrop = backdrop(darkSurface);
      expect(darkBackdrop, findsOneWidget);

      final overlayFinder = find.byType(AnnotatedRegion<SystemUiOverlayStyle>);
      expect(overlayFinder, findsOneWidget);
      final darkOverlay = tester
          .widget<AnnotatedRegion<SystemUiOverlayStyle>>(overlayFinder)
          .value;
      expect(darkOverlay.statusBarBrightness, Brightness.dark);
      expect(darkOverlay.statusBarIconBrightness, Brightness.light);
      expect(darkOverlay.systemNavigationBarIconBrightness, Brightness.light);
      expect(darkOverlay.systemNavigationBarColor, darkSurface);

      // The backdrop covers the whole window, including the strips behind the
      // status bar and home indicator that SafeArea pushes content out of.
      expect(
        tester.getRect(darkBackdrop),
        const Rect.fromLTWH(0, 0, 1200, 800),
      );

      // Switching themes recolors the strips to match. MaterialApp animates
      // the change over kThemeAnimationDuration, so step past it.
      await themeProvider.selectBuiltIn(BuiltInThemes.lightId);
      await tester.pump();
      await tester.pump(kThemeAnimationDuration);
      final lightSurface = themeProvider.lightTheme.scaffoldBackgroundColor;
      expect(backdrop(darkSurface), findsNothing);
      expect(backdrop(lightSurface), findsOneWidget);

      final lightOverlay = tester
          .widget<AnnotatedRegion<SystemUiOverlayStyle>>(overlayFinder)
          .value;
      expect(lightOverlay.statusBarBrightness, Brightness.light);
      expect(lightOverlay.statusBarIconBrightness, Brightness.dark);
      expect(lightOverlay.systemNavigationBarIconBrightness, Brightness.dark);
      expect(lightOverlay.systemNavigationBarColor, lightSurface);
    },
  );

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
      DevinoriumApp(
        appState: appState,
        themeProvider: themeProvider,
        zoomController: ZoomController(),
      ),
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
