import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as markdown;
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/app_state.dart';

class ThreadPage extends StatelessWidget {
  const ThreadPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final isNarrow = MediaQuery.of(context).size.width < 768;
    final title = state.activeThreadDetail?.thread.title ??
        'Select or create a thread';

    return Scaffold(
      appBar: AppBar(
        leading: isNarrow
            ? IconButton(
                icon: const Icon(Icons.menu),
                onPressed: () => Scaffold.of(context).openDrawer(),
              )
            : null,
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'File manager',
            icon: const Icon(Icons.folder_outlined),
            onPressed: state.openFilesPanel,
          ),
        ],
        backgroundColor: theme.colorScheme.surface,
        scrolledUnderElevation: 0,
      ),
      body: const ChatView(),
    );
  }
}

/// The chat view: a scrollable message list on top, and a fixed composer
/// at the bottom. The composer never scrolls off-screen because it lives
/// outside the messages' scroll view.
class ChatView extends StatefulWidget {
  const ChatView({super.key});

  @override
  State<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<ChatView> {
  final _scrollController = ScrollController();
  final _composerController = TextEditingController();
  bool _autoScroll = true;
  int _lastMessageCount = 0;
  String? _lastStreamingText;
  String? _lastStreamingThinking;
  int _lastToolCallCount = 0;
  String? _lastThreadId;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(() {
      // Disable auto-scroll when the user scrolls away from the bottom.
      if (_scrollController.hasClients) {
        final max = _scrollController.position.maxScrollExtent;
        final pos = _scrollController.position.pixels;
        _autoScroll = (max - pos) < 80;
      }
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _composerController.dispose();
    super.dispose();
  }

  void _maybeScrollToBottom({bool force = false}) {
    if (!force && !_autoScroll) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final detail = state.activeThreadDetail;
    final streaming = state.streamingText;
    final thinking = state.streamingThinking;
    final thinkingActive = state.streamingThinkingActive;
    final toolCalls = state.streamingToolCalls;

    // Auto-scroll only when:
    // - A new message was added (message count changed), OR
    // - Streaming text/thinking grew (new chunk arrived)
    // AND the user is already near the bottom.
    final msgCount = detail?.messages.length ?? 0;
    final newMessage = msgCount != _lastMessageCount;
    final newChunk = streaming != null && streaming != _lastStreamingText;
    final newThinking = thinking != null && thinking != _lastStreamingThinking;
    final toolCount = toolCalls.length;
    final newToolCall = toolCount != _lastToolCallCount;
    if (newMessage || newChunk || newThinking || newToolCall) {
      _maybeScrollToBottom();
    }
    _lastMessageCount = msgCount;
    _lastStreamingText = streaming;
    _lastStreamingThinking = thinking;
    _lastToolCallCount = toolCount;

    // When switching threads, reset auto-scroll and jump to bottom.
    final threadId = detail?.thread.id;
    if (threadId != _lastThreadId) {
      _lastThreadId = threadId;
      _autoScroll = true;
      _maybeScrollToBottom(force: true);
    }

    return Column(
      children: [
        Expanded(
          child: _MessagesPanel(
            detail: detail,
            streamingText: streaming,
            streamingThinking: thinking,
            streamingThinkingActive: thinkingActive,
            toolCalls: toolCalls,
            controller: _scrollController,
          ),
        ),
        _Composer(controller: _composerController),
      ],
    );
  }
}

class _MessagesPanel extends StatelessWidget {
  final ThreadDetail? detail;
  final String? streamingText;
  final String? streamingThinking;
  final bool streamingThinkingActive;
  final Map<String, ToolCallData> toolCalls;
  final ScrollController controller;
  const _MessagesPanel({
    required this.detail,
    required this.streamingText,
    required this.streamingThinking,
    required this.streamingThinkingActive,
    required this.toolCalls,
    required this.controller,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (detail == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(48),
          child: Text(
            'Select or create a thread to start chatting.',
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    final messages = detail!.messages;
    final hasStreaming = streamingText != null;

    if (messages.isEmpty && !hasStreaming) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(48),
          child: Text(
            'Start the conversation by sending a message below.',
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    // Tool calls belong to the current assistant turn, which is the last
    // assistant message (or the streaming assistant bubble when active).
    final thinking = streamingThinking;
    final activeToolCalls = toolCalls.values.toList();
    Message? currentAssistant;
    final history = messages.toList();
    if (history.isNotEmpty && history.last.role == 'assistant') {
      currentAssistant = history.removeLast();
    }

    return ListView(
      controller: controller,
      padding: const EdgeInsets.symmetric(vertical: 24),
      children: [
        for (final m in history) _MessageItem(message: m),
        if (currentAssistant != null)
          _MessageItem(
            message: currentAssistant,
            toolCalls: activeToolCalls,
          ),
        if (hasStreaming)
          _MessageItem(
            message: Message(
              role: 'assistant',
              content: streamingText!,
              thinking: thinking,
              attachments: null,
            ),
            thinkingActive: streamingThinkingActive,
            toolCalls: activeToolCalls,
          ),
      ],
    );
  }
}

class _MessageItem extends StatefulWidget {
  final Message message;
  final bool thinkingActive;
  final List<ToolCallData> toolCalls;
  const _MessageItem({
    required this.message,
    this.thinkingActive = false,
    this.toolCalls = const [],
  });

  @override
  State<_MessageItem> createState() => _MessageItemState();
}

class _MessageItemState extends State<_MessageItem> {
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    _expanded = widget.thinkingActive || widget.toolCalls.isNotEmpty;
  }

  @override
  void didUpdateWidget(covariant _MessageItem old) {
    super.didUpdateWidget(old);
    if ((widget.thinkingActive || widget.toolCalls.isNotEmpty) && !_expanded) {
      setState(() => _expanded = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final message = widget.message;
    final (icon, label, avatarBg, avatarFg) = switch (message.role) {
      'user' => (
        Icons.person_outline,
        'You',
        theme.colorScheme.primaryContainer,
        theme.colorScheme.onPrimaryContainer,
      ),
      'assistant' => (
        Icons.smart_toy_outlined,
        'Assistant',
        theme.colorScheme.secondaryContainer,
        theme.colorScheme.onSecondaryContainer,
      ),
      _ => (
        Icons.warning_amber_outlined,
        'Error',
        theme.colorScheme.errorContainer,
        theme.colorScheme.onErrorContainer,
      ),
    };

    final thinking = message.thinking;
    final hasThinking =
        (thinking != null && thinking.isNotEmpty) || widget.toolCalls.isNotEmpty;

    Widget buildExpandedContent() {
      final children = <Widget>[];
      if (widget.toolCalls.isNotEmpty) {
        children.addAll(
          widget.toolCalls.map((t) => _ToolCallItem(tool: t)),
        );
      }
      if (thinking != null && thinking.isNotEmpty) {
        children.add(
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.access_time,
                size: 16,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SelectableText(
                  thinking,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    height: 1.5,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: children,
      );
    }

    Widget thinkingSection() {
      final anyToolRunning = widget.toolCalls.any(
        (t) => t.status != 'completed' && t.status != 'failed',
      );
      final working = widget.thinkingActive || anyToolRunning;
      final label = working
          ? 'Thinking'
          : (_expanded ? 'Hide thinking' : 'Show thinking');
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(20),
            child: Container(
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainer,
                borderRadius: BorderRadius.circular(20),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (working) _ThinkingDots(active: widget.thinkingActive),
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            firstChild: const SizedBox.shrink(),
            secondChild: Container(
              width: double.infinity,
              margin: const EdgeInsets.only(top: 8),
              padding: const EdgeInsets.only(left: 12, top: 4, bottom: 4),
              decoration: BoxDecoration(
                border: Border(
                  left: BorderSide(
                    color: theme.colorScheme.outline,
                    width: 2,
                  ),
                ),
              ),
              child: buildExpandedContent(),
            ),
            crossFadeState:
                _expanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
            duration: const Duration(milliseconds: 200),
            sizeCurve: Curves.easeInOut,
          ),
          const SizedBox(height: 12),
        ],
      );
    }

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 16,
                backgroundColor: avatarBg,
                foregroundColor: avatarFg,
                child: Icon(icon, size: 18),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label,
                        style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            fontWeight: FontWeight.w500)),
                    const SizedBox(height: 4),
                    if (hasThinking) thinkingSection(),
                    if (message.content.isNotEmpty)
                      if (message.role == 'assistant')
                        MarkdownBody(
                          data: message.content,
                          selectable: true,
                          extensionSet: markdown.ExtensionSet.gitHubFlavored,
                          styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
                            p: theme.textTheme.bodyLarge
                                ?.copyWith(height: 1.5),
                            code: theme.textTheme.bodySmall?.copyWith(
                              fontFamily: 'monospace',
                              backgroundColor:
                                  theme.colorScheme.surfaceContainerHigh,
                            ),
                            codeblockDecoration: BoxDecoration(
                              color: theme.colorScheme.surfaceContainerHigh,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            codeblockPadding: const EdgeInsets.all(12),
                            tableHead: theme.textTheme.bodySmall?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: theme.colorScheme.onSurface,
                            ),
                            tableBody: theme.textTheme.bodyMedium,
                            tableBorder: TableBorder(
                              horizontalInside: BorderSide(
                                color: theme.dividerColor.withAlpha(128),
                              ),
                            ),
                            tableCellsPadding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 4),
                          ),
                        )
                      else
                        Text(message.content,
                            style: theme.textTheme.bodyLarge
                                ?.copyWith(height: 1.5)),
                    if (message.role == 'assistant' &&
                        message.content.isEmpty &&
                        !hasThinking)
                      Text(
                        '...',
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    if (message.attachments != null &&
                        message.attachments!.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final a in message.attachments!)
                            Chip(
                              avatar: const Icon(Icons.attach_file, size: 14),
                              label: Text(a.filename),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 4, vertical: 0),
                              visualDensity: VisualDensity.compact,
                              backgroundColor:
                                  theme.colorScheme.surfaceContainerHigh,
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ThinkingDots extends StatefulWidget {
  final bool active;
  const _ThinkingDots({required this.active});

  @override
  State<_ThinkingDots> createState() => _ThinkingDotsState();
}

class _ThinkingDotsState extends State<_ThinkingDots>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    if (widget.active) _controller.repeat();
  }

  @override
  void didUpdateWidget(covariant _ThinkingDots old) {
    super.didUpdateWidget(old);
    if (widget.active && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!widget.active && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: _controller,
      builder: (_, child) {
        final dotCount = ((_controller.value * 3).floor() % 3) + 1;
        return Text('.' * dotCount);
      },
    );
  }
}

class _Composer extends StatefulWidget {
  final TextEditingController controller;
  const _Composer({required this.controller});

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  final _focusNode = FocusNode();

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  void _submit(AppState state) {
    if (state.composerText.trim().isNotEmpty &&
        state.activeThreadId != null &&
        !state.sending) {
      widget.controller.clear();
      state.sendMessage();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final isSending = state.sending;
    final hasActiveThread = state.activeThreadId != null;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Material(
              color: theme.colorScheme.surfaceContainer,
              elevation: 1,
              borderRadius: BorderRadius.circular(28),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    KeyboardListener(
                      focusNode: _focusNode,
                      onKeyEvent: (event) {
                        // Enter (without Shift) sends the message.
                        // Shift+Enter inserts a newline (default behavior).
                        if (event is KeyDownEvent &&
                            event.logicalKey == LogicalKeyboardKey.enter &&
                            !HardwareKeyboard.instance.isShiftPressed) {
                          _submit(state);
                        }
                      },
                      child: TextField(
                        controller: widget.controller,
                        minLines: 1,
                        maxLines: 6,
                        enabled: hasActiveThread && !isSending,
                        decoration: const InputDecoration(
                          border: InputBorder.none,
                          isCollapsed: true,
                          hintText:
                              'Ask for follow-up changes or attach images',
                        ),
                        style: theme.textTheme.bodyLarge,
                        onChanged: state.setComposerText,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 0,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              _ModelDropdown(
                                value: state.selectedModel,
                                models: state.models,
                                onChanged: (model) {
                                  state.setSelectedModel(model);
                                  state.saveThreadSettings();
                                },
                              ),
                              _PermissionDropdown(
                                value: state.selectedPermission,
                                onChanged: (mode) {
                                  state.setSelectedPermission(mode);
                                  state.saveThreadSettings();
                                },
                              ),
                            ],
                          ),
                        ),
                        IconButton.filled(
                          icon: isSending
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2),
                                )
                              : const Icon(Icons.send, size: 18),
                          onPressed: (hasActiveThread && !isSending)
                              ? () {
                                  if (state.composerText.trim().isNotEmpty) {
                                    widget.controller.clear();
                                    state.sendMessage();
                                  }
                                }
                              : null,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ModelDropdown extends StatelessWidget {
  final String value;
  final List<ModelInfo> models;
  final ValueChanged<String> onChanged;
  const _ModelDropdown({
    required this.value,
    required this.models,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final fallbackItems = value.isNotEmpty && !models.any((m) => m.id == value)
        ? [DropdownMenuItem<String>(value: value, child: Text(value))]
        : <DropdownMenuItem<String>>[];
    final items = [
      for (final m in models)
        DropdownMenuItem<String>(value: m.id, child: Text(m.label)),
      ...fallbackItems,
    ];
    final effectiveValue = items.any((i) => i.value == value) ? value : null;

    return DropdownButton<String>(
      value: effectiveValue,
      hint: const Text('Model'),
      underline: const SizedBox(),
      isDense: true,
      items: items,
      onChanged: (v) {
        if (v != null) onChanged(v);
      },
    );
  }
}

class _PermissionDropdown extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;
  const _PermissionDropdown({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    const modes = [
      ('normal', 'Ask every time'),
      ('accept-edits', 'Confirm edits'),
      ('smart', 'Smart confirm'),
      ('bypass', 'Auto-run'),
    ];
    final fallback = !modes.any((m) => m.$1 == value)
        ? [DropdownMenuItem<String>(value: value, child: Text(value))]
        : <DropdownMenuItem<String>>[];
    final items = [
      for (final (id, label) in modes)
        DropdownMenuItem<String>(value: id, child: Text(label)),
      ...fallback,
    ];
    final effectiveValue = items.any((i) => i.value == value) ? value : null;

    return DropdownButton<String>(
      value: effectiveValue,
      underline: const SizedBox(),
      isDense: true,
      items: items,
      onChanged: (v) {
        if (v != null) onChanged(v);
      },
    );
  }
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

class _ToolCallItem extends StatefulWidget {
  final ToolCallData tool;
  const _ToolCallItem({required this.tool});

  @override
  State<_ToolCallItem> createState() => _ToolCallItemState();
}

class _ToolCallItemState extends State<_ToolCallItem> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tool = widget.tool;
    final preview = tool.outputPreview ?? tool.command ?? '';

    final (icon, iconColor) = _toolIconAndColor(tool.kind, theme);

    final (statusIcon, statusColor) = switch (tool.status) {
      'completed' => (Icons.check, theme.colorScheme.primary),
      'failed' => (Icons.error_outline, theme.colorScheme.error),
      'pending' => (Icons.hourglass_empty, theme.colorScheme.onSurfaceVariant),
      _ => (Icons.play_circle_outline, theme.colorScheme.onSurfaceVariant),
    };

    return InkWell(
      onTap: () => setState(() => _expanded = !_expanded),
      borderRadius: BorderRadius.circular(6),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        decoration: BoxDecoration(
          color: _expanded
              ? theme.colorScheme.surfaceContainer
              : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        margin: const EdgeInsets.only(bottom: 2),
        child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(icon, size: 16, color: iconColor),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          tool.title,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurface,
                            fontWeight: FontWeight.w500,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Icon(statusIcon, size: 14, color: statusColor),
                      const SizedBox(width: 4),
                      Icon(
                        _expanded ? Icons.expand_less : Icons.expand_more,
                        size: 14,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ],
                  ),
                  if (_expanded)
                    Padding(
                      padding: const EdgeInsets.only(top: 8, left: 24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (preview.isNotEmpty)
                            _ToolDetailRow(
                              label: 'Preview',
                              value: preview,
                            ),
                          if (tool.command != null && tool.command!.isNotEmpty)
                            _ToolDetailRow(
                              label: 'Command',
                              value: tool.command!,
                            ),
                          if (tool.output != null && tool.output!.isNotEmpty)
                            _ToolDetailRow(
                              label: 'Output',
                              value: tool.output!,
                            ),
                          if (tool.changedFiles.isNotEmpty)
                            _ToolDetailRow(
                              label: 'Changed',
                              value: tool.changedFiles.join('\n'),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}

class _ToolDetailRow extends StatelessWidget {
  final String label;
  final String value;
  const _ToolDetailRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 2),
          SelectableText(
            value,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }
}


