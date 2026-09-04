import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import 'drop_zone.dart';
import 'editor/editor_page.dart';
import 'files_panel.dart';
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
  double _filesPanelWidth = 360;

  static const double _minSidebarWidth = 240;
  static const double _maxSidebarWidth = 420;
  static const double _minFilesPanelWidth = 240;
  static const double _maxFilesPanelWidth = 1200;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final isNarrow = MediaQuery.of(context).size.width < 768;

    // A stable key lets Flutter reparent this subtree (and preserve all
    // stateful descendants such as text controllers) when the layout
    // switches between narrow and wide, instead of rebuilding it.
    final main = DropZone(key: _mainKey, child: _MainArea());

    final isEditor = state.appMode == AppMode.editor;

    if (isNarrow) {
      if (state.filesPanelOpen && !_wasFilesPanelOpen && !isEditor) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _scaffoldKey.currentState?.openEndDrawer();
        });
      }
      _wasFilesPanelOpen = isEditor ? false : state.filesPanelOpen;

      return Scaffold(
        key: _scaffoldKey,
        drawer: const Drawer(width: 300, child: Sidebar()),
        body: main,
        endDrawer: !isEditor && state.filesPanelOpen
            ? const Drawer(width: 360, child: FilesPanel())
            : null,
        onEndDrawerChanged: (opened) {
          if (!opened && state.filesPanelOpen && !isEditor) {
            state.closeFilesPanel();
          }
        },
      );
    }

    _wasFilesPanelOpen = isEditor ? false : state.filesPanelOpen;

    return Scaffold(
      body: Row(
        children: [
          SizedBox(width: _sidebarWidth, child: const Sidebar()),
          _ResizeHandle(
            onDrag: (delta) => setState(() {
              _sidebarWidth =
                  (_sidebarWidth + delta).clamp(_minSidebarWidth, _maxSidebarWidth);
            }),
          ),
          Expanded(child: main),
          if (!isEditor && state.filesPanelOpen) ...[
            _ResizeHandle(
              onDrag: (delta) => setState(() {
                _filesPanelWidth =
                    (_filesPanelWidth + delta).clamp(_minFilesPanelWidth, _maxFilesPanelWidth);
              }),
            ),
            SizedBox(width: _filesPanelWidth, child: const FilesPanel()),
          ],
        ],
      ),
    );
  }
}

class _MainArea extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (state.appMode == AppMode.editor) {
      return const EditorPage();
    }
    switch (state.page) {
      case MainPage.threads:
        return const ThreadPage();
      case MainPage.settings:
        return const SettingsPage();
    }
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
          width: 8,
          color: theme.colorScheme.outlineVariant.withAlpha(0),
          child: VerticalDivider(
            width: 1,
            color: theme.colorScheme.outlineVariant,
          ),
        ),
      ),
    );
  }
}
