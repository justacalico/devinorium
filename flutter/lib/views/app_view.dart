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
          const SizedBox(width: 300, child: Sidebar()),
          const VerticalDivider(width: 1),
          Expanded(child: main),
          if (!isEditor && state.filesPanelOpen) ...[
            const VerticalDivider(width: 1),
            const SizedBox(width: 360, child: FilesPanel()),
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
