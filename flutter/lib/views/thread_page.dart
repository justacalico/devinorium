import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as markdown;
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../utils/thread_status.dart';
import '../widgets/thread_tag.dart';
import 'drop_zone.dart';
import 'model_picker.dart';
import 'read_file_tool.dart';

class ThreadPage extends StatelessWidget {
  const ThreadPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final isNarrow = MediaQuery.of(context).size.width < 768;
    final thread = state.activeThreadDetail?.thread;
    final title = thread?.title ?? l10n(context).selectOrCreateThread;
    final repo = state.activeProjectId != null ? state.gitRepoInfo(state.activeProjectId!) : null;
    final isGit = repo?.isRepo ?? false;
    final tag = thread != null
        ? activeThreadTag(
            sending: state.sending,
            messages: state.activeThreadDetail?.messages ?? const [],
            pendingPermissionRequest: state.pendingPermissionRequest,
          )
        : null;

    return Scaffold(
      appBar: AppBar(
        leading: isNarrow
            ? IconButton(
                icon: const Icon(Icons.menu),
                onPressed: () => Scaffold.of(context).openDrawer(),
              )
            : null,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
            if (tag != null) ...[
              const SizedBox(height: 2),
              ThreadTag(tag),
            ],
          ],
        ),
        actions: [
          if (isGit && state.activeProjectId != null)
            TextButton.icon(
              icon: const Icon(Icons.call_split, size: 18),
              label: Text(
                thread?.branch ?? repo!.branch,
                style: const TextStyle(fontSize: 12),
              ),
              onPressed: () => state.openGitBranchDialog(state.activeProjectId!),
            ),
          IconButton(
            tooltip: l10n(context).fileManager,
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
  String _lastStreamingDigest = '';
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
    final streamingParts = state.streamingParts;
    final thinkingActive = state.streamingThinkingActive;

    final msgCount = detail?.messages.length ?? 0;
    final newMessage = msgCount != _lastMessageCount;
    final digest = streamingParts
        .map((p) => '${p.type}:${p.id ?? ''}:${p.content ?? ''}')
        .join('|');
    final newParts = digest != _lastStreamingDigest;
    if (newMessage || newParts) {
      _maybeScrollToBottom();
    }
    _lastMessageCount = msgCount;
    _lastStreamingDigest = digest;

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
            streamingParts: streamingParts,
            streamingThinkingActive: thinkingActive,
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
  final List<MessagePart> streamingParts;
  final bool streamingThinkingActive;
  final ScrollController controller;
  const _MessagesPanel({
    required this.detail,
    required this.streamingParts,
    required this.streamingThinkingActive,
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
            l10n(context).selectOrCreateThreadToChat,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    final messages = detail!.messages;
    final hasStreaming = streamingParts.isNotEmpty;

    if (messages.isEmpty && !hasStreaming) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(48),
          child: Text(
            l10n(context).startConversationHint,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

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
        if (currentAssistant != null) _MessageItem(message: currentAssistant),
        if (hasStreaming)
          _MessageItem(
            message: Message(
              role: 'assistant',
              content: '',
              attachments: null,
              parts: streamingParts,
            ),
            thinkingActive: streamingThinkingActive,
          ),
      ],
    );
  }
}

class _MessageItem extends StatefulWidget {
  final Message message;
  final bool thinkingActive;
  const _MessageItem({
    required this.message,
    this.thinkingActive = false,
  });

  @override
  State<_MessageItem> createState() => _MessageItemState();
}

class _ThinkingItem {
  final String type;
  final String? content;
  final ToolCallData? tool;
  _ThinkingItem({required this.type, this.content, this.tool});
}

class _PartGroup {
  final String type;
  final String? content;
  final List<_ThinkingItem> thinkingItems;
  _PartGroup({
    required this.type,
    this.content,
    this.thinkingItems = const [],
  });
}

class _MessageItemState extends State<_MessageItem> {
  bool _expanded = false;

  bool get _working {
    if (widget.thinkingActive) return true;
    return widget.message.allParts.any((p) =>
        p.type == 'tool_call' &&
        p.toolCall != null &&
        p.toolCall!.status != 'completed' &&
        p.toolCall!.status != 'failed');
  }

  bool get _hasText => widget.message.allParts.any(
        (p) => p.type == 'text' && (p.content?.isNotEmpty ?? false),
      );

  @override
  void initState() {
    super.initState();
    _expanded = _working && !_hasText;
  }

  @override
  void didUpdateWidget(covariant _MessageItem old) {
    super.didUpdateWidget(old);
    final oldHasText = old.message.allParts.any(
      (p) => p.type == 'text' && (p.content?.isNotEmpty ?? false),
    );
    if ((oldHasText == false && _hasText) ||
        (old.thinkingActive && !widget.thinkingActive && _hasText)) {
      if (_expanded) setState(() => _expanded = false);
      return;
    }
    if (_working && !_expanded) {
      setState(() => _expanded = true);
    }
  }

  List<_PartGroup> _buildGroups(List<MessagePart> parts) {
    final thinkingItems = <_ThinkingItem>[];
    final groups = <_PartGroup>[];

    for (final part in parts) {
      if (part.type == 'thinking') {
        final text = part.content ?? '';
        if (thinkingItems.isNotEmpty &&
            thinkingItems.last.type == 'thinking') {
          final merged = thinkingItems.last.content ?? '';
          thinkingItems.last = _ThinkingItem(
            type: 'thinking',
            content: merged + text,
          );
        } else {
          thinkingItems.add(_ThinkingItem(
            type: 'thinking',
            content: text,
          ));
        }
      } else if (part.type == 'tool_call') {
        final tool = part.toolCall;
        if (tool != null) {
          thinkingItems.add(_ThinkingItem(type: 'tool_call', tool: tool));
        }
      } else if (part.type == 'text') {
        final text = part.content ?? '';
        if (groups.isNotEmpty && groups.last.type == 'text') {
          final merged = groups.last.content ?? '';
          groups.last = _PartGroup(type: 'text', content: merged + text);
        } else {
          groups.add(_PartGroup(type: 'text', content: text));
        }
      }
    }

    if (thinkingItems.isNotEmpty) {
      groups.insert(
        0,
        _PartGroup(type: 'thinking', thinkingItems: thinkingItems),
      );
    }

    return groups;
  }

  Widget _buildTextContent(BuildContext context, String text, String role) {
    final theme = Theme.of(context);
    if (role == 'assistant') {
      return MarkdownBody(
        data: text,
        selectable: true,
        extensionSet: markdown.ExtensionSet.gitHubFlavored,
        styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
          p: theme.textTheme.bodyLarge?.copyWith(height: 1.5),
          code: theme.textTheme.bodySmall?.copyWith(
            fontFamily: 'monospace',
            backgroundColor: theme.colorScheme.surfaceContainerHigh,
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
          tableCellsPadding:
              const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        ),
      );
    }
    return Text(text,
        style: theme.textTheme.bodyLarge?.copyWith(height: 1.5));
  }

  Widget _buildPartWidgets(BuildContext context, List<_PartGroup> groups) {
    final children = <Widget>[];
    for (final group in groups) {
      if (group.type == 'text') {
        children.add(_buildTextContent(
            context, group.content ?? '', widget.message.role));
      } else if (group.type == 'thinking') {
        children.add(_ThinkingBlock(
          items: group.thinkingItems,
          working: _working,
          expanded: _expanded,
          onToggle: () => setState(() => _expanded = !_expanded),
        ));
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final message = widget.message;
    final l = l10n(context);
    final (icon, label, avatarBg, avatarFg) = switch (message.role) {
      'user' => (
        Icons.person_outline,
        l.messageRoleYou,
        theme.colorScheme.primaryContainer,
        theme.colorScheme.onPrimaryContainer,
      ),
      'assistant' => (
        Icons.smart_toy_outlined,
        l.messageRoleAssistant,
        theme.colorScheme.secondaryContainer,
        theme.colorScheme.onSecondaryContainer,
      ),
      _ => (
        Icons.warning_amber_outlined,
        l.messageRoleError,
        theme.colorScheme.errorContainer,
        theme.colorScheme.onErrorContainer,
      ),
    };

    final groups = _buildGroups(message.allParts);
    final showLoading = message.role == 'assistant' &&
        message.content.isEmpty &&
        groups.isEmpty;

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
                    if (groups.isNotEmpty) _buildPartWidgets(context, groups),
                    if (showLoading)
                      Text(
                        l10n(context).messageLoading,
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

class _ThinkingBlock extends StatelessWidget {
  final List<_ThinkingItem> items;
  final bool working;
  final bool expanded;
  final VoidCallback onToggle;
  const _ThinkingBlock({
    required this.items,
    required this.working,
    required this.expanded,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = l10n(context);
    final label = working
        ? l.thinking
        : (expanded ? l.hideThinking : l.showThinking);

    Widget expandedContent() {
      final children = <Widget>[];
      for (final item in items) {
        if (item.type == 'thinking' && (item.content?.isNotEmpty ?? false)) {
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
                    item.content!,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      height: 1.5,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          );
        } else if (item.type == 'tool_call') {
          final tool = item.tool;
          if (tool != null) {
            children.add(_ToolCallItem(tool: tool));
          }
        }
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: children,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: onToggle,
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
                  expanded ? Icons.expand_less : Icons.expand_more,
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
                if (working) _ThinkingDots(active: working),
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
            child: expandedContent(),
          ),
          crossFadeState:
              expanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
          duration: const Duration(milliseconds: 200),
          sizeCurve: Curves.easeInOut,
        ),
        const SizedBox(height: 12),
      ],
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
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (state.attachments.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (var i = 0; i < state.attachments.length; i++)
                              Chip(
                                avatar:
                                    const Icon(Icons.attach_file, size: 14),
                                label: Text(state.attachments[i].filename),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                  vertical: 0,
                                ),
                                visualDensity: VisualDensity.compact,
                                backgroundColor:
                                    theme.colorScheme.surfaceContainerHigh,
                                onDeleted: () => state.removeAttachment(i),
                              ),
                          ],
                        ),
                      ),
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
                        decoration: InputDecoration(
                          border: InputBorder.none,
                          isCollapsed: true,
                          hintText: l10n(context).composerHint,
                        ),
                        style: theme.textTheme.bodyLarge,
                        onChanged: state.setComposerText,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.attach_file, size: 20),
                          onPressed: hasActiveThread && !isSending
                              ? () async {
                                  final dz = DropZone.of(context);
                                  if (dz == null) return;
                                  final files = await dz.pick(multiple: true);
                                  if (files.isNotEmpty) {
                                    state.addAttachments(files);
                                  }
                                }
                              : null,
                        ),
                        Expanded(
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 0,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              ModelPicker(
                                value: state.selectedModel,
                                models: state.models,
                                enabled: hasActiveThread && !isSending,
                                onChanged: (model) {
                                  state.setSelectedModel(model);
                                  state.saveThreadSettings();
                                },
                              ),
                              _PermissionDropdown(
                                value: state.selectedPermission,
                                enabled: hasActiveThread && !isSending,
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

class _PermissionDropdown extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;
  final bool enabled;
  const _PermissionDropdown({
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final l = l10n(context);
    final modes = [
      ('normal', l.permissionModeNormal),
      ('accept-edits', l.permissionModeAcceptEdits),
      ('smart', l.permissionModeSmart),
      ('bypass', l.permissionModeBypass),
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
      onChanged: enabled
          ? (v) {
              if (v != null) onChanged(v);
            }
          : null,
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
    final l = l10n(context);
    final tool = widget.tool;
    final preview = tool.outputPreview ?? tool.command ?? '';

    if (tool.kind == 'read') {
      return ReadFileTool(key: ValueKey(tool.id), tool: tool);
    }

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
                              label: l.preview,
                              value: preview,
                            ),
                          if (tool.command != null && tool.command!.isNotEmpty)
                            _ToolDetailRow(
                              label: l.command,
                              value: tool.command!,
                            ),
                          if (tool.output != null && tool.output!.isNotEmpty)
                            _ToolDetailRow(
                              label: l.output,
                              value: tool.output!,
                            ),
                          if (tool.changedFiles.isNotEmpty)
                            _ToolDetailRow(
                              label: l.changed,
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


