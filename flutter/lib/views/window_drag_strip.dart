import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../services/window_actions.dart';

/// A transparent top strip that lets the user drag the window.
///
/// Wraps [child] in a [Stack] and adds a 40 px hit region at the very top
/// that starts a window drag. On web or non-desktop
/// platforms the widget just passes [child] through unchanged.
class WindowDragStrip extends StatelessWidget {
  final Widget child;

  const WindowDragStrip({super.key, required this.child});

  bool _isDesktop(BuildContext context) {
    if (kIsWeb) return false;
    return switch (Theme.of(context).platform) {
      TargetPlatform.linux ||
      TargetPlatform.macOS ||
      TargetPlatform.windows =>
        true,
      _ => false,
    };
  }

  @override
  Widget build(BuildContext context) {
    if (!_isDesktop(context)) {
      return child;
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onPanStart: (_) => startWindowDragging(),
            child: Container(
              key: const Key('window_drag_strip'),
              height: 40,
              color: Colors.transparent,
            ),
          ),
        ),
      ],
    );
  }
}
