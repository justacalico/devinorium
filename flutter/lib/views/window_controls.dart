import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../services/window_actions.dart';

/// macOS-style traffic-light window controls for desktop.
///
/// Renders close, minimize, and maximize buttons as colored circles.
/// The window action symbols appear on hover. On non-desktop platforms
/// the widget collapses to nothing.
class WindowControls extends StatelessWidget {
  const WindowControls({super.key});

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
      return const SizedBox.shrink();
    }

    final l = l10n(context);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _TrafficLight(
          key: const Key('window_close_button'),
          color: const Color(0xFFFF5F57),
          icon: Icons.close,
          onPressed: closeWindow,
          tooltip: l.windowClose,
        ),
        const SizedBox(width: 8),
        _TrafficLight(
          key: const Key('window_minimize_button'),
          color: const Color(0xFFFFBD2E),
          icon: Icons.remove,
          onPressed: minimizeWindow,
          tooltip: l.windowMinimize,
        ),
        const SizedBox(width: 8),
        _TrafficLight(
          key: const Key('window_maximize_button'),
          color: const Color(0xFF28CA41),
          icon: Icons.add,
          onPressed: toggleMaximize,
          tooltip: l.windowZoom,
        ),
      ],
    );
  }
}

class _TrafficLight extends StatefulWidget {
  final Color color;
  final IconData icon;
  final VoidCallback onPressed;
  final String tooltip;

  const _TrafficLight({
    super.key,
    required this.color,
    required this.icon,
    required this.onPressed,
    required this.tooltip,
  });

  @override
  State<_TrafficLight> createState() => _TrafficLightState();
}

class _TrafficLightState extends State<_TrafficLight> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onPressed,
        child: Tooltip(
          message: widget.tooltip,
          child: Container(
            width: 24,
            height: 24,
            alignment: Alignment.center,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 100),
              width: _hovered ? 14 : 12,
              height: _hovered ? 14 : 12,
              decoration: BoxDecoration(
                color: widget.color,
                shape: BoxShape.circle,
              ),
              child: _hovered
                  ? Icon(
                      widget.icon,
                      size: 8,
                      color: Colors.black.withAlpha(140),
                    )
                  : null,
            ),
          ),
        ),
      ),
    );
  }
}
