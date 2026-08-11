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

    // Auto-scroll only when:
    // - A new message was added (message count changed), OR
    // - Streaming text grew (new chunk arrived)
    // AND the user is already near the bottom.
    final msgCount = detail?.messages.length ?? 0;
    final newMessage = msgCount != _lastMessageCount;
    final newChunk = streaming != null && streaming != _lastStreamingText;
    if (newMessage || newChunk) {
      _maybeScrollToBottom();
    }
    _lastMessageCount = msgCount;
    _lastStreamingText = streaming;

    // When switching threads, reset auto-scroll and jump to bottom.
    final threadId = detail?.thread.id;
    if (threadId != _lastThreadId) {
      _lastThreadId = threadId;
      _autoScroll = true;
      _maybeScrollToBottom(force: true);
    }

    return Column(
      children: [
        Expanded(child: _MessagesPanel(detail: detail, streamingText: streaming, controller: _scrollController)),
        _Composer(controller: _composerController),
      ],
    );
  }
}

class _MessagesPanel extends StatelessWidget {
  final ThreadDetail? detail;
  final String? streamingText;
  final ScrollController controller;
  const _MessagesPanel({
    required this.detail,
    required this.streamingText,
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

    return ListView(
      controller: controller,
      padding: const EdgeInsets.symmetric(vertical: 24),
      children: [
        for (final m in messages) _MessageItem(message: m),
        if (hasStreaming)
          _MessageItem(
            message: Message(
              role: 'assistant',
              content: streamingText!,
              attachments: null,
            ),
          ),
      ],
    );
  }
}

class _MessageItem extends StatelessWidget {
  final Message message;
  const _MessageItem({required this.message});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
                                onChanged: state.setSelectedModel,
                              ),
                              _PermissionDropdown(
                                value: state.selectedPermission,
                                onChanged: (mode) {
                                  state.setSelectedPermission(mode);
                                  state.saveThreadSettings();
                                },
                              ),
                              _PermissionsInput(
                                value: state.selectedPermissionsText,
                                onChanged: state.setSelectedPermissionsText,
                                onSave: state.saveThreadSettings,
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
    return DropdownButton<String>(
      value: value.isEmpty ? null : value,
      hint: const Text('Model'),
      underline: const SizedBox(),
      isDense: true,
      items: [
        for (final m in models)
          DropdownMenuItem(value: m.id, child: Text(m.label)),
      ],
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
      ('normal', 'Normal'),
      ('accept-edits', 'Accept edits'),
      ('smart', 'Smart'),
      ('bypass', 'Bypass'),
    ];
    return DropdownButton<String>(
      value: value,
      underline: const SizedBox(),
      isDense: true,
      items: [
        for (final (id, label) in modes)
          DropdownMenuItem(value: id, child: Text(label)),
      ],
      onChanged: (v) {
        if (v != null) onChanged(v);
      },
    );
  }
}

class _PermissionsInput extends StatefulWidget {
  final String value;
  final ValueChanged<String> onChanged;
  final VoidCallback onSave;
  const _PermissionsInput({
    required this.value,
    required this.onChanged,
    required this.onSave,
  });

  @override
  State<_PermissionsInput> createState() => _PermissionsInputState();
}

class _PermissionsInputState extends State<_PermissionsInput> {
  late TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value);
  }

  @override
  void didUpdateWidget(_PermissionsInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) {
      _controller.text = widget.value;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IntrinsicWidth(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 180,
            child: TextField(
              controller: _controller,
              minLines: 1,
              maxLines: 3,
              decoration: const InputDecoration(
                hintText: 'Exec(curl), Fetch(**)',
                isCollapsed: true,
                border: InputBorder.none,
                contentPadding: EdgeInsets.symmetric(vertical: 8),
              ),
              onChanged: widget.onChanged,
              onSubmitted: (_) => widget.onSave(),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.check, size: 18),
            tooltip: 'Save permissions',
            onPressed: widget.onSave,
          ),
        ],
      ),
    );
  }
}
