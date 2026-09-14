import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../state/zoom_controller.dart';

/// Browser-style zoom for desktop builds.
///
/// Lays the app out at a smaller or larger logical size and scales the result
/// back to the window, so the whole UI reflows the way a web page does under
/// page zoom. Handles Ctrl (Cmd on macOS) + `+`/`-` to zoom and `0` to reset.
class DesktopZoom extends StatefulWidget {
  const DesktopZoom({super.key, required this.child});

  final Widget child;

  @override
  State<DesktopZoom> createState() => _DesktopZoomState();
}

class _DesktopZoomState extends State<DesktopZoom> {
  Timer? _badgeTimer;
  bool _badgeVisible = false;

  @override
  void initState() {
    super.initState();
    if (ZoomController.isDesktop) {
      HardwareKeyboard.instance.addHandler(_onKeyEvent);
    }
  }

  @override
  void dispose() {
    _badgeTimer?.cancel();
    HardwareKeyboard.instance.removeHandler(_onKeyEvent);
    super.dispose();
  }

  bool _onKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
    if (!mounted) return false;

    final keyboard = HardwareKeyboard.instance;
    // Exactly one modifier, like browsers: Ctrl on Linux/Windows, Cmd on macOS.
    // Shift is allowed (Ctrl+Shift+= is the "+" key on US layouts), Alt is not.
    final isMac = defaultTargetPlatform == TargetPlatform.macOS;
    final modifier = isMac ? keyboard.isMetaPressed : keyboard.isControlPressed;
    final other = isMac ? keyboard.isControlPressed : keyboard.isMetaPressed;
    if (!modifier || other || keyboard.isAltPressed) return false;

    final zoom = context.read<ZoomController>();
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.equal ||
        key == LogicalKeyboardKey.add ||
        key == LogicalKeyboardKey.numpadAdd ||
        key == LogicalKeyboardKey.numpadEqual) {
      zoom.zoomIn();
    } else if (key == LogicalKeyboardKey.minus ||
        key == LogicalKeyboardKey.numpadSubtract) {
      zoom.zoomOut();
    } else if (key == LogicalKeyboardKey.digit0 ||
        key == LogicalKeyboardKey.numpad0) {
      zoom.reset();
    } else {
      return false;
    }
    _flashBadge();
    return true;
  }

  void _flashBadge() {
    _badgeTimer?.cancel();
    setState(() => _badgeVisible = true);
    _badgeTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _badgeVisible = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!ZoomController.isDesktop) return widget.child;

    final zoom = context.watch<ZoomController>();
    final mediaQuery = MediaQuery.of(context);
    final scaledSize = mediaQuery.size / zoom.factor;

    // FittedBox sizes itself to the window and hit-tests the child in the
    // child's own coordinates, so pointer input lands correctly at every
    // zoom level (Transform.scale + OverflowBox leaves dead zones at the
    // edges for one of the two zoom directions). The wrapper stays mounted
    // at 100% too so crossing it never remounts the app subtree.
    final content = MediaQuery(
      data: mediaQuery.copyWith(
        size: scaledSize,
        padding: mediaQuery.padding / zoom.factor,
        viewPadding: mediaQuery.viewPadding / zoom.factor,
        viewInsets: mediaQuery.viewInsets / zoom.factor,
        systemGestureInsets: mediaQuery.systemGestureInsets / zoom.factor,
      ),
      child: FittedBox(
        fit: BoxFit.fill,
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: scaledSize.width,
          height: scaledSize.height,
          child: widget.child,
        ),
      ),
    );

    return Stack(
      fit: StackFit.expand,
      children: [
        content,
        Positioned(
          top: 16,
          left: 0,
          right: 0,
          child: IgnorePointer(
            child: Center(
              child: AnimatedOpacity(
                opacity: _badgeVisible ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 150),
                child: _ZoomBadge(percent: zoom.percent),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ZoomBadge extends StatelessWidget {
  const _ZoomBadge({required this.percent});

  final int percent;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.inverseSurface,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Text(
          '$percent%',
          style: TextStyle(color: colors.onInverseSurface),
        ),
      ),
    );
  }
}
