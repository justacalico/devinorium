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
/// On narrow screens, the sidebar becomes a drawer.
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _mainKey = GlobalKey();
  bool _wasFilesPanelOpen = false;
  double _sidebarWidth = 300;

  static const double _minSidebarWidth = 240;
  static const double _maxSidebarWidth = 420;

  @override
  Widget build(BuildContext context) {
    return Selector<AppState, bool>(
      selector: (_, state) => state.filesPanelOpen,
      builder: (context, filesPanelOpen, _) {
        final isNarrow = MediaQuery.of(context).size.width < 768;

        // A stable key lets Flutter reparent this subtree (and preserve all
        // stateful descendants such as text controllers) when the layout
        // switches between narrow and wide, instead of rebuilding it.
        final main = DropZone(key: _mainKey, child: _MainArea());

        if (isNarrow) {
          // The files view lives inside the unified sidebar, so opening it on a
          // narrow screen opens the sidebar drawer instead of a second panel.
          if (filesPanelOpen && !_wasFilesPanelOpen) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _scaffoldKey.currentState?.openDrawer();
            });
          }
          _wasFilesPanelOpen = filesPanelOpen;

          return Scaffold(
            key: _scaffoldKey,
            drawer: const Drawer(width: 300, child: Sidebar()),
            body: main,
            onDrawerChanged: (opened) {
              if (!opened && filesPanelOpen) {
                context.read<AppState>().closeFilesPanel();
              }
            },
          );
        }

        _wasFilesPanelOpen = filesPanelOpen;

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
