import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import 'drop_zone.dart';
import 'editor/editor_page.dart';
import 'settings_page.dart';
import 'sidebar.dart';
import 'thread_page.dart';

/// The main authenticated layout: sidebar + main content area.
/// Uses a Row with a fixed-width sidebar (300px) and a flexible main area.
/// On narrow screens, the sidebar becomes a slide-over panel.
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  final _mainKey = GlobalKey();
  bool _wasSidePanelOpen = false;
  bool _wasSidebarOpen = false;
  bool _autoNarrow = false;
  bool _sidebarDragging = false;
  bool _wasCompact = false;
  double _sidebarWidth = 300;
  double _preDragWidth = 300;
  double _edgeDragDx = 0;
  double _panelDragDx = 0;
  double _dragOvershoot = 0;

  static const double _maxSidebarWidth = 420;
  static const double _overlayWidth = 300;
  static const double _autoCollapseWindowWidth = 880;
  static const Duration _sidebarAnimDuration = Duration(milliseconds: 200);

  /// Re-engagement gap: once collapsed, the window must grow past this
  /// before the auto-collapse can trigger again, so hovering near the
  /// boundary doesn't flicker the layout.
  static const double _autoCollapseHysteresis = 40;
  static const double _collapseOvershoot = 48;

  /// How far the rail's handle has to be pulled right before it expands;
  /// keeps an accidental brush from undoing the collapse.
  static const double _expandDragThreshold = 24;

  @override
  Widget build(BuildContext context) {
    return Selector<
      AppState,
      ({bool sidePanelOpen, bool sidebarOpen, bool compact})
    >(
      selector: (_, state) => (
        sidePanelOpen: state.filesPanelOpen || state.gitPanelOpen,
        sidebarOpen: state.sidebarOpen,
        compact: state.sidebarCompact,
      ),
      builder: (context, model, _) {
        final windowWidth = MediaQuery.of(context).size.width;
        final isNarrow = windowWidth < kWideLayoutMinWidth;
        final state = context.read<AppState>();

        // A stable key lets Flutter reparent this subtree (and preserve all
        // stateful descendants such as text controllers) when the layout
        // switches between narrow and wide, instead of rebuilding it.
        final main = DropZone(key: _mainKey, child: _MainArea());

        if (isNarrow) {
          // Side panels live inside the unified sidebar, so opening one on a
          // narrow screen opens the sidebar overlay instead of a second panel.
          if (model.sidePanelOpen && !_wasSidePanelOpen) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              state.openSidebar();
            });
          }
          _wasSidePanelOpen = model.sidePanelOpen;

          if (_wasSidebarOpen && !model.sidebarOpen && model.sidePanelOpen) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (state.filesPanelOpen) state.closeFilesPanel();
              if (state.gitPanelOpen) state.closeGitPanel();
            });
          }
          _wasSidebarOpen = model.sidebarOpen;

          final overlayWidth = math.min(
            _overlayWidth,
            MediaQuery.of(context).size.width * 0.85,
          );

          // The sidebar is a slide-over inside the body rather than a
          // Scaffold drawer: a drawer unmounts its subtree when it closes,
          // which would cancel drags started in it. Here the panel stays
          // mounted while sliding off-screen, so a thread dragged out of the
          // sidebar survives long enough to reach the composer drop target.
          return Scaffold(
            body: PopScope(
              canPop: !model.sidebarOpen,
              onPopInvokedWithResult: (didPop, _) {
                if (!didPop) state.closeSidebar();
              },
              child: Stack(
                children: [
                  main,
                  if (model.sidebarOpen)
                    Positioned.fill(
                      key: const ValueKey('sidebar-scrim'),
                      child: GestureDetector(
                        onTap: state.closeSidebar,
                        child: const ColoredBox(color: Colors.black38),
                      ),
                    ),
                  // Keys keep the panel element (and the whole Sidebar
                  // subtree, including in-progress Draggables) alive when the
                  // scrim and edge strip appear and disappear around it.
                  AnimatedPositioned(
                    key: const ValueKey('sidebar-panel'),
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOutCubic,
                    left: model.sidebarOpen ? 0 : -overlayWidth,
                    top: 0,
                    bottom: 0,
                    width: overlayWidth,
                    child: GestureDetector(
                      onHorizontalDragStart: (_) => _panelDragDx = 0,
                      onHorizontalDragUpdate: (details) {
                        _panelDragDx += details.delta.dx;
                        if (_panelDragDx < -60) {
                          _panelDragDx = 0;
                          state.closeSidebar();
                        }
                      },
                      onHorizontalDragEnd: (_) => _panelDragDx = 0,
                      onHorizontalDragCancel: () => _panelDragDx = 0,
                      child: const Material(elevation: 16, child: Sidebar()),
                    ),
                  ),
                  if (!model.sidebarOpen)
                    Positioned(
                      key: const ValueKey('sidebar-edge'),
                      left: 0,
                      top: 0,
                      bottom: 0,
                      width: 24,
                      child: GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onHorizontalDragStart: (_) => _edgeDragDx = 0,
                        onHorizontalDragUpdate: (details) {
                          _edgeDragDx += details.delta.dx;
                          if (_edgeDragDx > 60) {
                            _edgeDragDx = 0;
                            state.openSidebar();
                          }
                        },
                        onHorizontalDragEnd: (_) => _edgeDragDx = 0,
                        onHorizontalDragCancel: () => _edgeDragDx = 0,
                      ),
                    ),
                ],
              ),
            ),
          );
        }

        _wasSidePanelOpen = model.sidePanelOpen;
        _wasSidebarOpen = model.sidebarOpen;
        if (model.sidebarOpen) {
          // The overlay flag only means something on narrow screens; clear it
          // so coming back to a narrow layout doesn't reopen it unexpectedly.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            state.closeSidebar();
          });
        }

        // Below this window width the expanded sidebar crowds out the main
        // area, so it drops to the rail until the window widens again. The
        // hysteresis keeps a resize hovering at the boundary from
        // flickering between modes.
        final autoNarrow = _autoNarrow
            ? windowWidth < _autoCollapseWindowWidth + _autoCollapseHysteresis
            : windowWidth < _autoCollapseWindowWidth;
        if (autoNarrow != _autoNarrow) {
          _autoNarrow = autoNarrow;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) state.setSidebarCompactAuto(autoNarrow);
          });
        }

        // Resize drags track the pointer 1:1; only mode flips ease,
        // including the snap a drag itself triggers.
        final animateWidth = !_sidebarDragging || _wasCompact != model.compact;
        _wasCompact = model.compact;

        return Scaffold(
          body: Row(
            children: [
              AnimatedContainer(
                duration: animateWidth ? _sidebarAnimDuration : Duration.zero,
                curve: Curves.easeOutCubic,
                width: model.compact ? kCompactRailWidth : _sidebarWidth,
                child: const Sidebar(),
              ),
              _ResizeHandle(
                onDragStart: () {
                  _preDragWidth = _sidebarWidth;
                  _sidebarDragging = true;
                },
                onDrag: (delta) => _onSidebarDrag(state, delta),
                onDragEnd: () {
                  _dragOvershoot = 0;
                  _sidebarDragging = false;
                },
                onDoubleTap: state.toggleSidebarCompact,
              ),
              Expanded(child: main),
            ],
          ),
        );
      },
    );
  }

  /// Dragging past the minimum width snaps the sidebar into the rail;
  /// pulling right from the rail expands it back to the pre-drag width.
  /// The compact state is read live rather than passed in, since the
  /// gesture can outlive the build it started in.
  void _onSidebarDrag(AppState state, double delta) {
    if (state.sidebarCompact) {
      _dragOvershoot = math.max(0.0, _dragOvershoot + delta);
      if (_dragOvershoot >= _expandDragThreshold) {
        _dragOvershoot = 0;
        state.setSidebarCompact(false);
      }
      return;
    }
    final next = _sidebarWidth + delta;
    if (next < kSidebarMinWidth) {
      _dragOvershoot += kSidebarMinWidth - next;
      if (_dragOvershoot >= _collapseOvershoot) {
        _dragOvershoot = 0;
        state.setSidebarCompact(true);
        // Restore what the sidebar was before this drag, not the clamp.
        // Skipped when the collapse was refused (e.g. editor mode), which
        // would otherwise snap the width back and jitter during the drag.
        if (state.sidebarCompact) _sidebarWidth = _preDragWidth;
        return;
      }
    } else {
      _dragOvershoot = 0;
      setState(() {
        _sidebarWidth = next.clamp(kSidebarMinWidth, _maxSidebarWidth);
      });
    }
  }
}

class _MainArea extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Selector<AppState, ({AppMode appMode, MainPage page})>(
      selector: (_, state) => (appMode: state.appMode, page: state.page),
      builder: (context, model, _) {
        if (model.appMode == AppMode.editor) {
          return const EditorPage();
        }
        return switch (model.page) {
          MainPage.threads => const ThreadPage(),
          MainPage.settings => const SettingsPage(),
        };
      },
    );
  }
}

class _ResizeHandle extends StatelessWidget {
  final VoidCallback? onDragStart;
  final ValueChanged<double> onDrag;
  final VoidCallback? onDragEnd;
  final VoidCallback? onDoubleTap;

  const _ResizeHandle({
    required this.onDrag,
    this.onDragStart,
    this.onDragEnd,
    this.onDoubleTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      child: GestureDetector(
        key: const Key('sidebar_resize_handle'),
        behavior: HitTestBehavior.translucent,
        onHorizontalDragStart: (_) => onDragStart?.call(),
        onHorizontalDragUpdate: (details) => onDrag(details.delta.dx),
        onHorizontalDragEnd: (_) => onDragEnd?.call(),
        onHorizontalDragCancel: () => onDragEnd?.call(),
        onDoubleTap: onDoubleTap,
        child: Container(
          width: 10,
          color: theme.colorScheme.outlineVariant.withAlpha(40),
          alignment: Alignment.center,
          child: VerticalDivider(width: 2, color: theme.colorScheme.outline),
        ),
      ),
    );
  }
}
