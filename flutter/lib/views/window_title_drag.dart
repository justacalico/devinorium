import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../services/window_actions.dart';

/// Wraps an AppBar title so it becomes a drag region on desktop.
///
/// The title slot is made full-width and tappable child gestures
/// (menu, terminal, folder, etc.) are not blocked because they sit in
/// the AppBar's leading/actions area, outside this widget.
/// On web or mobile the child is passed through unchanged.
class WindowTitleDrag extends StatelessWidget {
  final Widget child;

  const WindowTitleDrag({super.key, required this.child});

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

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) => startWindowDragging(),
      onDoubleTap: toggleMaximize,
      child: Container(
        color: Colors.transparent,
        width: double.infinity,
        alignment: Alignment.center,
        child: child,
      ),
    );
  }
}
