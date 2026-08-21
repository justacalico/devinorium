import 'package:flutter/material.dart';

import '../services/window_actions.dart';

/// Desktop-only title bar drawn in Flutter.
///
/// Replaces the native GTK/Win32/Cocoa title bar on Linux, Windows, and macOS.
/// Includes a drag region for moving the window and minimize / maximize /
/// close buttons.
class WindowTitleBar extends StatelessWidget {
  final Widget? title;

  const WindowTitleBar({
    super.key,
    this.title,
  });

  bool _isDesktop(BuildContext context) =>
      switch (Theme.of(context).platform) {
        TargetPlatform.linux ||
        TargetPlatform.macOS ||
        TargetPlatform.windows =>
          true,
        _ => false,
      };

  @override
  Widget build(BuildContext context) {
    if (!_isDesktop(context)) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      height: 40,
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          bottom: BorderSide(
            color: theme.dividerColor.withAlpha(80),
          ),
        ),
      ),
      child: Row(
        children: [
          // Drag region (moves the window).
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onPanStart: (_) => startWindowDragging(),
              onDoubleTap: toggleMaximize,
              child: Padding(
                padding: const EdgeInsets.only(left: 16),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: DefaultTextStyle(
                    style: theme.textTheme.titleSmall!.copyWith(
                      color: theme.colorScheme.onSurface,
                    ),
                    child: title ?? const Text('Devinorium'),
                  ),
                ),
              ),
            ),
          ),
          // Window controls.
          _WindowButton(
            icon: Icons.remove,
            onPressed: minimizeWindow,
            isDark: isDark,
          ),
          _WindowButton(
            icon: Icons.crop_square,
            onPressed: toggleMaximize,
            isDark: isDark,
          ),
          _WindowButton(
            icon: Icons.close,
            onPressed: closeWindow,
            isDark: isDark,
            isClose: true,
          ),
        ],
      ),
    );
  }
}

class _WindowButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onPressed;
  final bool isDark;
  final bool isClose;

  const _WindowButton({
    required this.icon,
    required this.onPressed,
    required this.isDark,
    this.isClose = false,
  });

  @override
  Widget build(BuildContext context) {
    final hoverColor = isClose
        ? const Color(0xFFE81123)
        : (isDark ? Colors.white12 : Colors.black12);

    return SizedBox(
      width: 46,
      height: 40,
      child: IconButton(
        icon: Icon(icon, size: 16),
        color: Theme.of(context).colorScheme.onSurface,
        hoverColor: hoverColor,
        onPressed: onPressed,
        padding: EdgeInsets.zero,
        splashRadius: 18,
      ),
    );
  }
}
