import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_linkify/flutter_linkify.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart' hide SyntaxHighlighter;
import 'package:markdown/markdown.dart' as markdown;
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import '../models/composer_mode.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../utils/path_attachment.dart';
import '../utils/thread_status.dart';
import '../widgets/thread_tag.dart';
import 'ask_request_panel.dart';
import 'drop_zone.dart';
import 'code_block.dart';
import 'edit_file_tool.dart';
import 'elapsed_time_indicator.dart';
import 'model_picker.dart';
import 'read_file_tool.dart';
import 'run_command_tool.dart';
import 'syntax_highlighter.dart';

class ThreadPage extends StatelessWidget {
  const ThreadPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final isNarrow = MediaQuery.of(context).size.width < 768;
    final thread = state.activeThreadDetail?.thread;
    final title = thread?.title ?? l10n(context).selectOrCreateThread;
    final repo = state.activeProjectId != null
        ? state.gitRepoInfo(state.activeProjectId!)
        : null;
    final isGit = repo?.isRepo ?? false;
    final tag = thread != null
        ? activeThreadTag(
            sending: state.sending,
            messages: state.activeThreadDetail?.messages ?? const [],
            pendingPermissionRequest: state.pendingPermissionRequest,
            pendingAskRequest: state.pendingAskRequest,
            runStatus: state.lastRunStatus,
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
            if (tag != null) ...[const SizedBox(height: 2), ThreadTag(tag)],
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
              onPressed: () =>
                  state.openGitBranchDialog(state.activeProjectId!),
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

@immutable
class _ChatModel {
  final String? activeThreadId;
  final ThreadDetail? detail;
  final bool loading;
  final int messageCount;
  final int streamingDigest;
  final bool streamingThinkingActive;
  final String? pendingAskRequestId;

  const _ChatModel({
    required this.activeThreadId,
    required this.detail,
    required this.loading,
    required this.messageCount,
    required this.streamingDigest,
    required this.streamingThinkingActive,
    required this.pendingAskRequestId,
  });

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! _ChatModel) return false;
    return activeThreadId == other.activeThreadId &&
        detail == other.detail &&
        loading == other.loading &&
        messageCount == other.messageCount &&
        streamingDigest == other.streamingDigest &&
        streamingThinkingActive == other.streamingThinkingActive &&
        pendingAskRequestId == other.pendingAskRequestId;
  }

  @override
  int get hashCode => Object.hash(
        activeThreadId,
        detail,
        loading,
        messageCount,
        streamingDigest,
        streamingThinkingActive,
        pendingAskRequestId,
      );
}

int _streamingDigest(List<MessagePart> parts) {
  var h = parts.length;
  for (var i = 0; i < parts.length; i++) {
    final p = parts[i];
    final t = p.toolCall;
    h = Object.hash(
      h,
      p.type,
      p.id,
      p.content,
      t?.status,
      t?.output,
      i,
    );
  }
  return h;
}

class _ChatViewState extends State<ChatView> {
  static const _loadMoreThreshold = 800.0;
  static const _autoScrollThreshold = 80.0;

  final _scrollController = ScrollController();
  final _composerController = TextEditingController();
  bool _autoScroll = true;
  int _lastMessageCount = 0;
  int _lastStreamingDigest = 0;
  String? _lastThreadId;
  bool _loadingMore = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(() {
      if (!_scrollController.hasClients) return;
      final max = _scrollController.position.maxScrollExtent;
      final pos = _scrollController.position.pixels;
      _autoScroll = (max - pos) < _autoScrollThreshold;

      // Near the top means older messages are just off-screen.
      if (pos < _loadMoreThreshold && pos > 0 && !_loadingMore) {
        _loadingMore = true;
        final oldMax = _scrollController.position.maxScrollExtent;
        final state = context.read<AppState>();
        state.loadMoreMessages().whenComplete(() {
          _loadingMore = false;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!_scrollController.hasClients) return;
            final newMax = _scrollController.position.maxScrollExtent;
            final delta = newMax - oldMax;
            if (delta > 0 && pos < _loadMoreThreshold) {
              _scrollController.jumpTo((pos + delta).clamp(0, newMax));
            }
          });
        });
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
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Selector<AppState, _ChatModel>(
      selector: (_, state) => _ChatModel(
        activeThreadId: state.activeThreadId,
        detail: state.activeThreadDetail,
        loading: state.activeThreadLoading,
        messageCount: state.activeThreadDetail?.messages.length ?? 0,
        streamingDigest: _streamingDigest(state.streamingParts),
        streamingThinkingActive: state.streamingThinkingActive,
        pendingAskRequestId: state.pendingAskRequest?.requestId,
      ),
      shouldRebuild: (prev, next) => prev != next,
      builder: (context, model, child) {
        final state = context.read<AppState>();

        final msgCount = model.messageCount;
        final newMessage = msgCount != _lastMessageCount;
        final newParts = model.streamingDigest != _lastStreamingDigest;
        if (newMessage || newParts) {
          _maybeScrollToBottom();
        }
        _lastMessageCount = msgCount;
        _lastStreamingDigest = model.streamingDigest;

        final threadId = model.activeThreadId;
        if (threadId != _lastThreadId) {
          _lastThreadId = threadId;
          _autoScroll = true;
          _maybeScrollToBottom(force: true);
        }

        return Column(
          children: [
            Expanded(
              child: _MessagesPanel(
                detail: model.detail,
                loading: model.loading,
                streamingParts: state.streamingParts,
                streamingThinkingActive: model.streamingThinkingActive,
                controller: _scrollController,
              ),
            ),
            if (model.pendingAskRequestId != null)
              AskRequestPanel(
                key: ValueKey(model.pendingAskRequestId),
              )
            else if (!model.loading) ...[
              if (state.sending)
                Padding(
                  padding: const EdgeInsets.fromLTRB(32, 0, 24, 4),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: ElapsedTimeIndicator(
                      key: ValueKey(state.startedAt),
                      startedAt: state.startedAt,
                      active: state.sending,
                    ),
                  ),
                ),
              _Composer(controller: _composerController),
            ],
          ],
        );
      },
    );
  }
}

class _MessagesPanel extends StatelessWidget {
  final ThreadDetail? detail;
  final bool loading;
  final List<MessagePart> streamingParts;
  final bool streamingThinkingActive;
  final ScrollController controller;
  const _MessagesPanel({
    required this.detail,
    required this.loading,
    required this.streamingParts,
    required this.streamingThinkingActive,
    required this.controller,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (detail == null) {
      if (loading) {
        return Center(
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: theme.colorScheme.primary,
          ),
        );
      }
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(48),
          child: Text(
            l10n(context).selectOrCreateThreadToChat,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
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
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return SelectionArea(
      child: ListView.builder(
        controller: controller,
        padding: const EdgeInsets.symmetric(vertical: 24),
        addAutomaticKeepAlives: false,
        addRepaintBoundaries: true,
        scrollCacheExtent: const ScrollCacheExtent.pixels(200),
        itemCount: messages.length + (hasStreaming ? 1 : 0),
        itemBuilder: (context, index) {
          if (hasStreaming && index == messages.length) {
            return _MessageItem(
              key: const ValueKey('streaming'),
              message: Message(
                role: 'assistant',
                content: '',
                attachments: null,
                parts: streamingParts,
              ),
              thinkingActive: streamingThinkingActive,
            );
          }
          final message = messages[index];
          return _MessageItem(
            key: ValueKey(message.id ?? message.content),
            message: message,
          );
        },
      ),
    );
  }
}

class _MessageItem extends StatefulWidget {
  final Message message;
  final bool thinkingActive;
  const _MessageItem({super.key, required this.message, this.thinkingActive = false});

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
  final ToolCallData? tool;
  _PartGroup({
    required this.type,
    this.content,
    this.thinkingItems = const [],
    this.tool,
  });
}

class _MessageItemState extends State<_MessageItem> {
  bool get _working {
    if (widget.thinkingActive) return true;
    return widget.message.allParts.any(
      (p) =>
          p.type == 'tool_call' &&
          p.toolCall != null &&
          p.toolCall!.status != 'completed' &&
          p.toolCall!.status != 'failed',
    );
  }

  bool get _hasText => widget.message.allParts.any(
    (p) => p.type == 'text' && (p.content?.isNotEmpty ?? false),
  );

  List<_PartGroup> _buildGroups(List<MessagePart> parts) {
    final groups = <_PartGroup>[];

    for (final part in parts) {
      if (part.type == 'thinking') {
        final text = part.content ?? '';
        if (groups.isNotEmpty && groups.last.type == 'thinking') {
          final items = groups.last.thinkingItems;
          if (items.isNotEmpty && items.last.type == 'thinking') {
            final merged = items.last.content ?? '';
            items[items.length - 1] = _ThinkingItem(
              type: 'thinking',
              content: merged + text,
            );
          } else {
            items.add(_ThinkingItem(type: 'thinking', content: text));
          }
        } else {
          groups.add(_PartGroup(
            type: 'thinking',
            thinkingItems: [_ThinkingItem(type: 'thinking', content: text)],
          ));
        }
      } else if (part.type == 'tool_call') {
        final tool = part.toolCall;
        if (tool == null) continue;
        // File edits and command executions are rendered as standalone cards
        // outside the thinking block so the user can see them without expanding.
        if (tool.kind == 'edit' || tool.kind == 'execute') {
          groups.add(_PartGroup(type: 'tool_call', tool: tool));
        } else if (groups.isNotEmpty && groups.last.type == 'thinking') {
          groups.last.thinkingItems.add(
            _ThinkingItem(type: 'tool_call', tool: tool),
          );
        } else {
          groups.add(_PartGroup(
            type: 'thinking',
            thinkingItems: [_ThinkingItem(type: 'tool_call', tool: tool)],
          ));
        }
      } else if (part.type == 'text') {
        final text = part.content ?? '';
        if (groups.isNotEmpty && groups.last.type == 'text') {
          final merged = groups.last.content ?? '';
          groups[groups.length - 1] = _PartGroup(
            type: 'text',
            content: merged + text,
          );
        } else {
          groups.add(_PartGroup(type: 'text', content: text));
        }
      }
    }

    return groups;
  }

  Widget _buildTextContent(BuildContext context, String text, String role) {
    final theme = Theme.of(context);
    if (role == 'assistant') {
      final highlighter = SyntaxHighlighter(theme);
      return MarkdownBody(
        data: text,
        selectable: false,
        onTapLink: (txt, href, title) {
          if (href != null) context.read<AppState>().openLink(href);
        },
        extensionSet: markdown.ExtensionSet.gitHubFlavored,
        builders: {
          'pre': _PreBuilder(highlighter: highlighter),
        },
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
          tableCellsPadding: const EdgeInsets.symmetric(
            horizontal: 8,
            vertical: 4,
          ),
        ),
      );
    }
    return Linkify(
      text: text,
      onOpen: (link) => context.read<AppState>().openLink(link.url),
      style: theme.textTheme.bodyLarge?.copyWith(height: 1.5),
      linkStyle: theme.textTheme.bodyLarge?.copyWith(
        height: 1.5,
        color: theme.colorScheme.primary,
        decoration: TextDecoration.underline,
      ),
    );
  }

  Widget _buildPartWidgets(BuildContext context, List<_PartGroup> groups) {
    final children = <Widget>[];
    final hasText = _hasText;
    for (var i = 0; i < groups.length; i++) {
      final group = groups[i];
      if (group.type == 'text') {
        children.add(
          _buildTextContent(context, group.content ?? '', widget.message.role),
        );
      } else if (group.type == 'tool_call') {
        final tool = group.tool;
        if (tool != null) {
          children.add(_ToolCallItem(key: ValueKey('tool-group-$i'), tool: tool));
        }
      } else if (group.type == 'thinking') {
        final isLast = i == groups.length - 1;
        children.add(
          _ThinkingBlock(
            key: ValueKey('thinking-group-$i'),
            items: group.thinkingItems,
            working: isLast && _working,
            hasText: hasText,
          ),
        );
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
    final showLoading =
        message.role == 'assistant' &&
        message.content.isEmpty &&
        groups.isEmpty;

    return Padding(
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
                Text(
                  label,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 4),
                if (groups.isNotEmpty)
                  SelectionArea(child: _buildPartWidgets(context, groups)),
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
                            horizontal: 4,
                            vertical: 0,
                          ),
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
    );
  }
}

class _ThinkingBlock extends StatefulWidget {
  final List<_ThinkingItem> items;
  final bool working;
  final bool hasText;
  const _ThinkingBlock({
    super.key,
    required this.items,
    required this.working,
    required this.hasText,
  });

  @override
  State<_ThinkingBlock> createState() => _ThinkingBlockState();
}

class _ThinkingBlockState extends State<_ThinkingBlock> {
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    _expanded = widget.working && !widget.hasText;
  }

  @override
  void didUpdateWidget(covariant _ThinkingBlock old) {
    super.didUpdateWidget(old);
    if ((!old.hasText && widget.hasText) ||
        (old.working && !widget.working && widget.hasText)) {
      if (_expanded) setState(() => _expanded = false);
      return;
    }
    if (widget.working && !_expanded) {
      setState(() => _expanded = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = l10n(context);
    final label = widget.working
        ? l.thinking
        : (_expanded ? l.hideThinking : l.showThinking);

    Widget expandedContent() {
      final children = <Widget>[];
      for (final item in widget.items) {
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
                  child: Text(
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
                if (widget.working) _ThinkingDots(active: widget.working),
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
                left: BorderSide(color: theme.colorScheme.outline, width: 2),
              ),
            ),
            child: expandedContent(),
          ),
          crossFadeState: _expanded
              ? CrossFadeState.showSecond
              : CrossFadeState.showFirst,
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
  final _keyFocusNode = FocusNode();
  bool _wasSending = false;

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final state = context.read<AppState>();
    final shift = HardwareKeyboard.instance.isShiftPressed;
    if (event.logicalKey == LogicalKeyboardKey.enter && !shift) {
      _submit(state);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.tab && shift) {
      _cycleComposerMode(state);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyV &&
        (HardwareKeyboard.instance.isControlPressed ||
            HardwareKeyboard.instance.isMetaPressed)) {
      _handlePaste();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _handlePaste() async {
    final state = context.read<AppState>();
    final l = l10n(context);
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    final text = data?.text;
    if (text == null || text.isEmpty) return;

    final result = await maybeAttachPath(text);
    if (!mounted) return;
    switch (result) {
      case PathAttached():
        state.addAttachments([
          (
            filename: result.filename,
            mime: result.mime,
            bytes: result.bytes,
          ),
        ]);
      case PathTooLarge():
        state.setGlobalError(l.dropZoneFileTooLarge(result.filename));
      case PathFallback():
        _insertText(text);
    }
  }

  void _insertText(String text) {
    final state = context.read<AppState>();
    final value = widget.controller.value;
    final selection = value.selection;
    late final String newText;
    late final TextSelection newSelection;

    if (selection.isValid && selection.isCollapsed) {
      newText = value.text.replaceRange(selection.start, selection.end, text);
      newSelection = TextSelection.collapsed(
        offset: selection.start + text.length,
      );
    } else {
      newText = value.text + text;
      newSelection = TextSelection.collapsed(offset: newText.length);
    }

    widget.controller.value = value.copyWith(
      text: newText,
      selection: newSelection,
    );
    state.setComposerText(newText);
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _keyFocusNode.dispose();
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

  void _cycleComposerMode(AppState state) {
    state.setComposerMode(state.composerMode.next);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final state = context.read<AppState>();
    if (_wasSending && !state.sending) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focusNode.requestFocus();
      });
    }
    _wasSending = state.sending;
  }

  static Color _modeColor(ComposerMode mode) => switch (mode) {
    ComposerMode.code => Colors.transparent,
    ComposerMode.plan => const Color(0xFFFFC107),
    ComposerMode.ask => const Color(0xFF4CAF50),
  };

  static Color? _badgeBackground(ComposerMode mode) => switch (mode) {
    ComposerMode.code => null,
    ComposerMode.plan => const Color(0xFFFFECB3),
    ComposerMode.ask => const Color(0xFFC8E6C9),
  };

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final isSending = state.sending;
    final hasActiveThread = state.activeThreadId != null;
    final mode = state.composerMode;
    final modeColor = _modeColor(mode);
    final showBadge = mode != ComposerMode.code;

    final borderSide = mode == ComposerMode.code
        ? BorderSide.none
        : BorderSide(color: modeColor, width: 2);

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Material(
              color: theme.colorScheme.surfaceContainer,
              elevation: 1,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(28),
                side: borderSide,
              ),
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
                                avatar: const Icon(Icons.attach_file, size: 14),
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
                    Focus(
                      focusNode: _keyFocusNode,
                      onKeyEvent: _handleKeyEvent,
                      child: TextField(
                        controller: widget.controller,
                        focusNode: _focusNode,
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
                        contextMenuBuilder: (context, editableTextState) {
                          final items =
                              editableTextState.contextMenuButtonItems
                                  .map((item) {
                                    if (item.type ==
                                        ContextMenuButtonType.paste) {
                                      return ContextMenuButtonItem(
                                        label: item.label,
                                        onPressed: _handlePaste,
                                      );
                                    }
                                    return item;
                                  })
                                  .toList();
                          return AdaptiveTextSelectionToolbar.buttonItems(
                            buttonItems: items,
                            anchors: editableTextState.contextMenuAnchors,
                          );
                        },
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
                              _ModeDropdown(
                                value: state.composerMode,
                                enabled: hasActiveThread && !isSending,
                                onChanged: state.setComposerMode,
                              ),
                            ],
                          ),
                        ),
                        IconButton.filled(
                          style: isSending
                              ? IconButton.styleFrom(
                                  backgroundColor: theme.colorScheme.error,
                                  foregroundColor: theme.colorScheme.onError,
                                )
                              : null,
                          tooltip: isSending
                              ? l10n(context).stopGenerating
                              : l10n(context).send,
                          icon: isSending
                              ? const Icon(Icons.stop, size: 18)
                              : const Icon(Icons.send, size: 18),
                          onPressed: hasActiveThread
                              ? () {
                                  if (isSending) {
                                    state.stopThread();
                                  } else if (state.composerText
                                      .trim()
                                      .isNotEmpty) {
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
            if (showBadge)
              Positioned(
                top: -10,
                left: 20,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: _badgeBackground(mode),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: modeColor),
                  ),
                  child: Text(
                    mode.label,
                    style: const TextStyle(
                      color: Colors.black87,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
          ],
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

class _ModeDropdown extends StatelessWidget {
  final ComposerMode value;
  final ValueChanged<ComposerMode> onChanged;
  final bool enabled;
  const _ModeDropdown({
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final items = [
      for (final mode in ComposerMode.values)
        DropdownMenuItem<ComposerMode>(
          value: mode,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(_modeIcon(mode), size: 14),
              const SizedBox(width: 6),
              Text(mode.label),
            ],
          ),
        ),
    ];

    return DropdownButton<ComposerMode>(
      value: value,
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

  static IconData _modeIcon(ComposerMode mode) => switch (mode) {
    ComposerMode.code => Icons.code,
    ComposerMode.plan => Icons.lightbulb_outline,
    ComposerMode.ask => Icons.help_outline,
  };
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
  const _ToolCallItem({super.key, required this.tool});

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

    if (tool.kind == 'edit') {
      return EditFileTool(key: ValueKey(tool.id), tool: tool);
    }

    if (tool.kind == 'execute') {
      return RunCommandTool(key: ValueKey(tool.id), tool: tool);
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
                      _ToolDetailRow(label: l.preview, value: preview),
                    if (tool.command != null && tool.command!.isNotEmpty)
                      _ToolDetailRow(label: l.command, value: tool.command!),
                    if (tool.output != null && tool.output!.isNotEmpty)
                      _ToolDetailRow(label: l.output, value: tool.output!),
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
          Text(
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

/// Custom builder for `pre` elements that renders a [CodeBlock] with
/// syntax highlighting, language label, and copy button.
class _PreBuilder extends MarkdownElementBuilder {
  final SyntaxHighlighter highlighter;

  _PreBuilder({required this.highlighter});

  @override
  bool isBlockElement() => true;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    markdown.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    String code = '';
    String language = '';
    if (element.children != null && element.children!.isNotEmpty) {
      final child = element.children!.first;
      if (child is markdown.Element && child.tag == 'code') {
        final cls = child.attributes['class'] ?? '';
        if (cls.startsWith('language-')) {
          language = cls.substring('language-'.length);
        }
        for (final node in child.children ?? <markdown.Node>[]) {
          if (node is markdown.Text) {
            code += node.text;
          }
        }
      }
    }
    if (code.isEmpty) {
      for (final node in element.children ?? <markdown.Node>[]) {
        if (node is markdown.Text) {
          code += node.text;
        }
      }
    }
    return CodeBlock(
      code: code,
      language: language,
      highlighter: highlighter,
    );
  }
}
