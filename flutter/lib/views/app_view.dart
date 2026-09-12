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
  double _sidebarWidth = 300;
  double _edgeDragDx = 0;
  double _panelDragDx = 0;

  static const double _minSidebarWidth = 240;
  static const double _maxSidebarWidth = 420;
  static const double _overlayWidth = 300;

  @override
  Widget build(BuildContext context) {
    return Selector<AppState, ({bool sidePanelOpen, bool sidebarOpen})>(
      selector: (_, state) => (
        sidePanelOpen: state.filesPanelOpen || state.gitPanelOpen,
        sidebarOpen: state.sidebarOpen,
      ),
      builder: (context, model, _) {
        final isNarrow = MediaQuery.of(context).size.width < 768;
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

          final overlayWidth =
              math.min(_overlayWidth, MediaQuery.of(context).size.width * 0.85);

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

        return Scaffold(
          body: Row(
            children: [
              SizedBox(width: _sidebarWidth, child: const Sidebar()),
              _ResizeHandle(
                onDrag: (delta) => setState(() {
                  _sidebarWidth = (_sidebarWidth + delta)
                      .clamp(_minSidebarWidth, _maxSidebarWidth);
                }),
              ),
              Expanded(child: main),
            ],
          ),
        );
      },
    );
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
  final ValueChanged<double> onDrag;

  const _ResizeHandle({required this.onDrag});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragUpdate: (details) => onDrag(details.delta.dx),
        child: Container(
          width: 10,
          color: theme.colorScheme.outlineVariant.withAlpha(40),
          alignment: Alignment.center,
          child: VerticalDivider(
            width: 2,
            color: theme.colorScheme.outline,
          ),
        ),
      ),
    );
  }
}
