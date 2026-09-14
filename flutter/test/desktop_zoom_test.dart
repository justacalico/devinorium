import 'package:devinorium_frontend/state/zoom_controller.dart';
import 'package:devinorium_frontend/widgets/desktop_zoom.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Same wiring as production: DesktopZoom wraps the Navigator (and its
// overlay) through MaterialApp.builder.
Widget _wrap(ZoomController zoom, {required Widget child}) {
  return MaterialApp(
    builder: (context, navigator) =>
        ChangeNotifierProvider<ZoomController>.value(
          value: zoom,
          child: DesktopZoom(child: navigator ?? const SizedBox.shrink()),
        ),
    home: child,
  );
}

Finder _insideZoom(Type type) =>
    find.descendant(of: find.byType(DesktopZoom), matching: find.byType(type));

void main() {
  group('ZoomController', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('defaults to 100%', () {
      expect(ZoomController().factor, 1.0);
      expect(ZoomController().percent, 100);
    });

    test('steps through browser zoom levels', () {
      final zoom = ZoomController();
      zoom.zoomIn();
      expect(zoom.factor, 1.1);
      zoom.zoomIn();
      expect(zoom.factor, 1.25);
      zoom.zoomOut();
      expect(zoom.factor, 1.1);
      zoom.zoomOut();
      expect(zoom.factor, 1.0);
      zoom.zoomOut();
      expect(zoom.factor, 0.9);
    });

    test('clamps at the ends of the level list', () {
      final zoom = ZoomController();
      for (var i = 0; i < 30; i++) {
        zoom.zoomIn();
      }
      expect(zoom.factor, 5.0);
      for (var i = 0; i < 30; i++) {
        zoom.zoomOut();
      }
      expect(zoom.factor, 0.25);
    });

    test('reset returns to 100%', () {
      final zoom = ZoomController();
      zoom.zoomIn();
      zoom.zoomIn();
      zoom.reset();
      expect(zoom.factor, 1.0);
    });

    test('normalizes a factor between levels before stepping', () async {
      SharedPreferences.setMockInitialValues({'devinorium_zoom_factor': 1.05});
      final prefs = await SharedPreferences.getInstance();
      final zoom = ZoomController(prefs: prefs);
      await zoom.load();
      expect(zoom.factor, 1.05);
      zoom.zoomIn();
      expect(zoom.factor, 1.1);
      zoom.zoomOut();
      expect(zoom.factor, 1.0);
    });

    test('load restores a persisted factor', () async {
      SharedPreferences.setMockInitialValues({'devinorium_zoom_factor': 1.25});
      final prefs = await SharedPreferences.getInstance();
      final zoom = ZoomController(prefs: prefs);
      await zoom.load();
      expect(zoom.factor, 1.25);
      expect(zoom.percent, 125);
    });

    test('load ignores out-of-range values', () async {
      SharedPreferences.setMockInitialValues({'devinorium_zoom_factor': 99.0});
      final prefs = await SharedPreferences.getInstance();
      final zoom = ZoomController(prefs: prefs);
      await zoom.load();
      expect(zoom.factor, 1.0);
    });

    test('persists the factor after zooming', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final zoom = ZoomController(prefs: prefs);
      zoom.zoomIn();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(prefs.getDouble('devinorium_zoom_factor'), 1.1);
    });
  });

  group('DesktopZoom', () {
    // The platform override must be restored inside the test body: the
    // binding verifies debug variables before addTearDown callbacks run.
    Future<void> withPlatform(
      TargetPlatform platform,
      Future<void> Function() body,
    ) async {
      debugDefaultTargetPlatformOverride = platform;
      try {
        await body();
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    }

    testWidgets('ctrl +/- changes the factor and scales MediaQuery', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final zoom = ZoomController();
      MediaQueryData? observed;
      await withPlatform(TargetPlatform.linux, () async {
        await tester.pumpWidget(
          _wrap(
            zoom,
            child: Builder(
              builder: (context) {
                observed = MediaQuery.of(context);
                return const SizedBox.expand();
              },
            ),
          ),
        );
        await tester.pump();

        expect(observed!.size, const Size(800, 600));
        expect(_insideZoom(FittedBox), findsOneWidget);

        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.equal);
        await tester.pump();

        expect(zoom.factor, 1.1);
        expect(observed!.size.width, closeTo(800 / 1.1, 0.01));
        expect(observed!.size.height, closeTo(600 / 1.1, 0.01));
        expect(_insideZoom(FittedBox), findsOneWidget);
        expect(find.text('110%'), findsOneWidget);

        await tester.sendKeyEvent(LogicalKeyboardKey.minus);
        await tester.pump();
        expect(zoom.factor, 1.0);
        expect(observed!.size, const Size(800, 600));

        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      });
    });

    testWidgets('pointer input lands correctly when zoomed out', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final zoom = ZoomController();
      var taps = 0;
      await withPlatform(TargetPlatform.linux, () async {
        await tester.pumpWidget(
          _wrap(
            zoom,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => taps++,
              child: const SizedBox.expand(),
            ),
          ),
        );
        await tester.pump();

        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.minus);
        await tester.sendKeyEvent(LogicalKeyboardKey.minus);
        await tester.pump();
        expect(zoom.factor, 0.8);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

        // The far edges of the window must still hit the app, not a dead
        // zone left by the scale wrapper.
        await tester.tapAt(const Offset(799, 599));
        await tester.tapAt(const Offset(400, 300));
        await tester.tapAt(const Offset(1, 1));
        expect(taps, 3);
      });
    });

    testWidgets('pointer input lands correctly when zoomed in', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final zoom = ZoomController();
      var taps = 0;
      await withPlatform(TargetPlatform.linux, () async {
        await tester.pumpWidget(
          _wrap(
            zoom,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => taps++,
              child: const SizedBox.expand(),
            ),
          ),
        );
        await tester.pump();

        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        for (var i = 0; i < 5; i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.equal);
        }
        await tester.pump();
        expect(zoom.factor, 2.0);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

        await tester.tapAt(const Offset(799, 599));
        await tester.tapAt(const Offset(400, 300));
        await tester.tapAt(const Offset(1, 1));
        expect(taps, 3);
      });
    });

    testWidgets('app state survives crossing 100% zoom', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final zoom = ZoomController();
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await withPlatform(TargetPlatform.linux, () async {
        await tester.pumpWidget(
          _wrap(
            zoom,
            child: Material(
              child: Center(
                child: SizedBox(
                  width: 200,
                  child: TextField(controller: controller),
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        await tester.enterText(find.byType(TextField), 'hello');
        await tester.pump();

        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.equal);
        await tester.pump();
        expect(zoom.factor, 1.1);
        expect(controller.text, 'hello');

        await tester.sendKeyEvent(LogicalKeyboardKey.digit0);
        await tester.pump();
        expect(zoom.factor, 1.0);
        expect(controller.text, 'hello');
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      });
    });

    testWidgets('ctrl + 0 resets the factor', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final zoom = ZoomController();
      await withPlatform(TargetPlatform.linux, () async {
        await tester.pumpWidget(_wrap(zoom, child: const SizedBox.expand()));
        await tester.pump();

        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.equal);
        await tester.sendKeyEvent(LogicalKeyboardKey.equal);
        await tester.pump();
        expect(zoom.factor, 1.25);

        await tester.sendKeyEvent(LogicalKeyboardKey.digit0);
        await tester.pump();
        expect(zoom.factor, 1.0);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      });
    });

    testWidgets('meta modifier zooms on macOS, control does not', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final zoom = ZoomController();
      await withPlatform(TargetPlatform.macOS, () async {
        await tester.pumpWidget(_wrap(zoom, child: const SizedBox.expand()));
        await tester.pump();

        await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.equal);
        await tester.pump();
        expect(zoom.factor, 1.1);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);

        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.equal);
        await tester.pump();
        expect(zoom.factor, 1.1);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      });
    });

    testWidgets('meta modifier does not zoom on linux', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final zoom = ZoomController();
      await withPlatform(TargetPlatform.linux, () async {
        await tester.pumpWidget(_wrap(zoom, child: const SizedBox.expand()));
        await tester.pump();

        await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.equal);
        await tester.pump();
        expect(zoom.factor, 1.0);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      });
    });

    testWidgets('shift is allowed, alt is not', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final zoom = ZoomController();
      await withPlatform(TargetPlatform.linux, () async {
        await tester.pumpWidget(_wrap(zoom, child: const SizedBox.expand()));
        await tester.pump();

        // Ctrl+Shift+= is the literal "+" key on US layouts.
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.equal);
        await tester.pump();
        expect(zoom.factor, 1.1);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);

        await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.equal);
        await tester.pump();
        expect(zoom.factor, 1.1);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      });
    });

    testWidgets('numpad keys zoom', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final zoom = ZoomController();
      await withPlatform(TargetPlatform.linux, () async {
        await tester.pumpWidget(_wrap(zoom, child: const SizedBox.expand()));
        await tester.pump();

        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        // The linux key map used by the test simulator lacks the numpad
        // keys, so simulate them with the windows map.
        await tester.sendKeyEvent(
          LogicalKeyboardKey.numpadAdd,
          platform: 'windows',
        );
        await tester.pump();
        expect(zoom.factor, 1.1);
        await tester.sendKeyEvent(
          LogicalKeyboardKey.numpadSubtract,
          platform: 'windows',
        );
        await tester.pump();
        expect(zoom.factor, 1.0);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      });
    });

    testWidgets('keys without the modifier do not zoom', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final zoom = ZoomController();
      await withPlatform(TargetPlatform.linux, () async {
        await tester.pumpWidget(_wrap(zoom, child: const SizedBox.expand()));
        await tester.pump();

        await tester.sendKeyEvent(LogicalKeyboardKey.equal);
        await tester.sendKeyEvent(LogicalKeyboardKey.minus);
        await tester.pump();
        expect(zoom.factor, 1.0);
      });
    });

    testWidgets('zoom badge hides again after the timeout', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final zoom = ZoomController();
      await withPlatform(TargetPlatform.linux, () async {
        await tester.pumpWidget(_wrap(zoom, child: const SizedBox.expand()));
        await tester.pump();

        AnimatedOpacity badge() =>
            tester.widget<AnimatedOpacity>(_insideZoom(AnimatedOpacity));
        expect(badge().opacity, 0.0);

        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.equal);
        await tester.pump();
        expect(badge().opacity, 1.0);

        await tester.pump(const Duration(seconds: 1));
        expect(badge().opacity, 0.0);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      });
    });

    testWidgets('does nothing on non-desktop platforms', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final zoom = ZoomController();
      await withPlatform(TargetPlatform.android, () async {
        await tester.pumpWidget(_wrap(zoom, child: const SizedBox.expand()));
        await tester.pump();

        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.equal);
        await tester.pump();
        expect(zoom.factor, 1.0);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      });
    });

    // Regression test for overlay coordinate spaces: showMenu positions are
    // in overlay (scaled) coordinates, so the tap point must be converted
    // with ancestor: overlay, not to root-view coordinates.
    testWidgets('context menu lands at the pointer when zoomed', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final zoom = ZoomController();
      await withPlatform(TargetPlatform.linux, () async {
        await tester.pumpWidget(
          _wrap(
            zoom,
            child: Material(
              child: Builder(
                builder: (context) => GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onSecondaryTapUp: (details) {
                    final renderBox = context.findRenderObject()! as RenderBox;
                    final overlay =
                        Overlay.of(context).context.findRenderObject()!
                            as RenderBox;
                    final global = renderBox.localToGlobal(
                      details.localPosition,
                      ancestor: overlay,
                    );
                    showMenu<void>(
                      context: context,
                      position: RelativeRect.fromSize(
                        Rect.fromPoints(global, global.translate(2, 2)),
                        overlay.size,
                      ),
                      items: const [PopupMenuItem(child: Text('Item'))],
                    );
                  },
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        for (var i = 0; i < 5; i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.equal);
        }
        await tester.pump();
        expect(zoom.factor, 2.0);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

        // Right-click at (200, 150) in window coordinates. With the
        // coordinate mix-up the menu would open near (400, 300) instead.
        final gesture = await tester.startGesture(
          const Offset(200, 150),
          buttons: kSecondaryButton,
        );
        await gesture.up();
        await tester.pumpAndSettle();

        final itemTopLeft = tester.getTopLeft(
          find.byWidgetPredicate((widget) => widget is PopupMenuItem),
        );
        expect(itemTopLeft.dx, closeTo(200, 60));
        expect(itemTopLeft.dy, closeTo(150, 60));
      });
    });
  });
}
