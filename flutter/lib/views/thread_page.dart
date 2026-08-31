import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_linkify/flutter_linkify.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart'
    hide SyntaxHighlighter;
import 'package:markdown/markdown.dart' as markdown;
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import '../models/composer_mode.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../utils/path_attachment.dart';
import '../utils/plan_markup.dart';
import '../utils/thread_status.dart';
import '../widgets/thread_tag.dart';
import 'ask_request_panel.dart';
import 'branch_toolbar.dart';
import 'drop_zone.dart';
import 'code_block.dart';
import 'edit_file_tool.dart';
import 'elapsed_time_indicator.dart';
import 'model_picker.dart';
import '../terminal/thread_terminal_panel.dart';
import 'plan_overlay.dart';
import 'read_file_tool.dart';
import 'run_command_tool.dart';
import 'window_title_drag.dart';
import 'syntax_highlighter.dart';

part 'thread/chat_view.dart';
part 'thread/messages_panel.dart';
part 'thread/message_item.dart';
part 'thread/thinking_block.dart';
part 'thread/thinking_dots.dart';
part 'thread/composer.dart';
part 'thread/permission_dropdown.dart';
part 'thread/mode_dropdown.dart';
part 'thread/tool_call_item.dart';
part 'thread/tool_detail_row.dart';
part 'thread/pre_builder.dart';
part 'thread/linked_mr_chip.dart';
part 'thread/plan_overlay.dart';

class ThreadPage extends StatefulWidget {
  const ThreadPage({super.key});

  @override
  State<ThreadPage> createState() => _ThreadPageState();
}

class _ThreadPageState extends State<ThreadPage> {
  final _terminalOpenByThread = <String, bool>{};
  final _terminalHeightByThread = <String, double>{};

  static const _defaultTerminalHeight = 280.0;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final isNarrow = MediaQuery.of(context).size.width < 768;
    final thread = state.activeThreadDetail?.thread;
    final title = thread?.title ?? l10n(context).selectOrCreateThread;
    final tag = thread != null
        ? activeThreadTag(
            sending: state.sending,
            messages: state.activeThreadDetail?.messages ?? const [],
            pendingPermissionRequest: state.pendingPermissionRequest,
            pendingAskRequest: state.pendingAskRequest,
            runStatus: state.lastRunStatus,
          )
        : null;
    final activeThreadId = state.activeThreadId;
    final terminalOpen = activeThreadId != null &&
        (_terminalOpenByThread[activeThreadId] ?? false);
    final terminalHeight = activeThreadId != null
        ? (_terminalHeightByThread[activeThreadId] ?? _defaultTerminalHeight)
        : _defaultTerminalHeight;

    return Scaffold(
      appBar: AppBar(
        leading: isNarrow
            ? IconButton(
                icon: const Icon(Icons.menu),
                onPressed: () => Scaffold.of(context).openDrawer(),
              )
            : null,
        title: WindowTitleDrag(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (tag != null) ...[ThreadTag(tag), const SizedBox(width: 8)],
              Flexible(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        actions: [
          if (state.linkedMergeRequest != null)
            LinkedMergeRequestChip(mr: state.linkedMergeRequest!),
          if (state.activePlan != null)
            IconButton(
              tooltip: state.planOverlayVisible ? 'Hide plan' : 'Show plan',
              icon: Icon(
                state.planOverlayVisible
                    ? Icons.playlist_add_check
                    : Icons.playlist_add_check_outlined,
              ),
              onPressed: state.togglePlanOverlay,
            ),
          IconButton(
            tooltip: l10n(context).fileManager,
            icon: const Icon(Icons.folder_outlined),
            onPressed: state.openFilesPanel,
          ),
          if (activeThreadId != null)
            IconButton(
              tooltip: l10n(context).terminal,
              icon: const Icon(Icons.terminal),
              onPressed: () => _toggleTerminal(activeThreadId),
            ),
        ],
        centerTitle: false,
        backgroundColor: theme.colorScheme.surface,
        scrolledUnderElevation: 0,
      ),
      body: Column(
        children: [
          const Expanded(child: ChatView()),
          ThreadTerminalPanel(
            api: state.api,
            threadId: activeThreadId ?? '',
            open: terminalOpen,
            initialHeight: terminalHeight,
            onHeightChanged: (height) {
              if (activeThreadId != null) {
                _setTerminalHeight(activeThreadId, height);
              }
            },
            onClose: activeThreadId != null
                ? () => _toggleTerminal(activeThreadId)
                : null,
          ),
        ],
      ),
    );
  }

  void _toggleTerminal(String threadId) {
    setState(() {
      final open = !(_terminalOpenByThread[threadId] ?? false);
      _terminalOpenByThread[threadId] = open;
      if (open) {
        _terminalHeightByThread[threadId] ??= _defaultTerminalHeight;
      }
    });
  }

  void _setTerminalHeight(String threadId, double height) {
    setState(() => _terminalHeightByThread[threadId] = height);
  }
}

int _streamingDigest(List<MessagePart> parts) {
  var h = parts.length;
  for (var i = 0; i < parts.length; i++) {
    final p = parts[i];
    final t = p.toolCall;
    h = Object.hash(h, p.type, p.id, p.content, t?.status, t?.output, i);
  }
  return h;
}

(IconData, Color) _toolIconAndColor(String kind, ThemeData theme) {
  return switch (kind) {
    'read' => (Icons.file_open_outlined, theme.colorScheme.primary),
    'edit' => (Icons.edit_outlined, theme.colorScheme.tertiary),
    'delete' || 'move' => (Icons.delete_outlined, theme.colorScheme.error),
    'search' => (Icons.search, theme.colorScheme.primary),
    'execute' => (Icons.terminal, theme.colorScheme.secondary),
    'fetch' => (Icons.download_outlined, theme.colorScheme.primary),
    'think' => (Icons.psychology_outlined, theme.colorScheme.tertiary),
    _ => (Icons.build_outlined, theme.colorScheme.onSurfaceVariant),
  };
}
