part of '../thread_page.dart';

class _MessageItem extends StatefulWidget {
  final Message message;
  final String threadId;
  final bool thinkingActive;
  const _MessageItem({
    super.key,
    required this.message,
    required this.threadId,
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
  final ToolCallData? tool;
  _PartGroup({
    required this.type,
    this.content,
    this.thinkingItems = const [],
    this.tool,
  });
}

class _MessageItemState extends State<_MessageItem> {
  static const _maxPreviewChars = 600;
  static const _maxPreviewLines = 8;
  static const _minChunkChars = 10000;
  static const _maxChunkChars = 100000;

  late Message _message;
  late Message _previewMessage;
  List<_PartGroup> _partGroups = [];
  SyntaxHighlighter? _syntaxHighlighter;
  bool _expanded = false;
  bool _isFull = false;
  bool _loadingMore = false;
  String _error = '';
  bool _isVisible = false;
  ScrollPosition? _scrollPosition;
  bool _visibilityCheckScheduled = false;
  // Bumped whenever didUpdateWidget or _resetToPreview replaces _message. Stale
  // chunk responses see the mismatch and return without touching _loadingMore;
  // the caller that incremented the token is responsible for resetting the flag.
  int _loadToken = 0;

  @override
  void initState() {
    super.initState();
    _previewMessage = widget.message;
    _message = widget.message;
    _isFull = !_message.truncated;
    _partGroups = _buildGroups(_effectiveMessage.allParts);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final theme = Theme.of(context);
    _syntaxHighlighter = SyntaxHighlighter(theme);
    final position = Scrollable.maybeOf(context)?.position;
    if (position != _scrollPosition) {
      _scrollPosition?.isScrollingNotifier.removeListener(_onScrollActivity);
      _scrollPosition = position;
      _scrollPosition?.isScrollingNotifier.addListener(_onScrollActivity);
    }
    _maybeScheduleVisibilityCheck();
  }

  @override
  void didUpdateWidget(covariant _MessageItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    final incoming = widget.message;
    final idChanged = incoming.id != _previewMessage.id;
    if (idChanged ||
        incoming.truncated != _previewMessage.truncated ||
        incoming != _previewMessage) {
      _loadToken++;
      _previewMessage = incoming;
      _message = incoming;
      if (idChanged) {
        _expanded = false;
      }
      _isFull = !incoming.truncated;
      _loadingMore = false;
      _error = '';
      _partGroups = _buildGroups(_effectiveMessage.allParts);
      _maybeScheduleVisibilityCheck();
    }
  }

  @override
  void dispose() {
    _scrollPosition?.isScrollingNotifier.removeListener(_onScrollActivity);
    super.dispose();
  }

  bool get _isAssistant => _message.role == 'assistant';

  bool get _working {
    if (widget.thinkingActive) return true;
    return _message.allParts.any(
      (p) =>
          p.type == 'tool_call' &&
          p.toolCall != null &&
          p.toolCall!.status != 'completed' &&
          p.toolCall!.status != 'failed',
    );
  }

  bool get _hasText => _message.allParts.any(
    (p) => p.type == 'text' && (p.content?.isNotEmpty ?? false),
  );

  bool get _shouldCollapse {
    if (_message.role != 'user' || _expanded) return false;
    final lines = _message.content.split('\n').length;
    return _message.content.runes.length > _maxPreviewChars ||
        lines > _maxPreviewLines;
  }

  String? get _previewText {
    if (!_shouldCollapse) return null;
    final runes = _message.content.runes;
    final end = runes.length < _maxPreviewChars
        ? runes.length
        : _maxPreviewChars;
    final charsPreview = String.fromCharCodes(runes.take(end));
    final lines = _message.content
        .split('\n')
        .take(_maxPreviewLines)
        .join('\n');
    return lines.runes.length <= charsPreview.runes.length
        ? lines
        : charsPreview;
  }

  Message get _effectiveMessage {
    final preview = _previewText;
    if (preview != null) {
      return _message.copyWith(content: preview, parts: []);
    }
    return _message;
  }

  int _chunkSize(int total, int loaded) {
    final remaining = total - loaded;
    if (remaining <= _minChunkChars) return _minChunkChars;
    final target = math.max(1, (total / 5).ceil());
    return math.min(_maxChunkChars, math.max(_minChunkChars, target));
  }

  void _onScrollActivity() {
    if (!(_scrollPosition?.isScrollingNotifier.value ?? true)) {
      _maybeScheduleVisibilityCheck();
    }
  }

  void _maybeScheduleVisibilityCheck() {
    if (_scrollPosition?.isScrollingNotifier.value ?? false) return;
    if (_visibilityCheckScheduled) return;
    _visibilityCheckScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _visibilityCheckScheduled = false;
      if (mounted) _checkVisibility();
    });
  }

  static const _visibilityMargin = 64.0;

  void _checkVisibility() {
    if (!mounted) return;
    if (_scrollPosition?.isScrollingNotifier.value ?? false) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || box.size.isEmpty) return;

    final viewport = RenderAbstractViewport.of(box) as RenderBox?;
    if (viewport == null || viewport.size.isEmpty) return;

    final itemOffset = box.localToGlobal(Offset.zero, ancestor: viewport);
    final itemRect = itemOffset & box.size;
    final viewportRect = Offset.zero & viewport.size;
    final isVisible = itemRect.overlaps(
      viewportRect.inflate(_visibilityMargin),
    );

    final wasVisible = _isVisible;
    _isVisible = isVisible;

    if (!wasVisible && isVisible) {
      if (!_isFull && !_loadingMore && _message.truncated && _isAssistant) {
        _loadMoreChunks();
      }
    } else if (wasVisible && !isVisible) {
      _resetToPreview();
    }
  }

  void _resetToPreview() {
    final needsUpdate = _message != _previewMessage || _loadingMore;
    if (!needsUpdate) return;
    if (!mounted) return;
    _loadToken++;
    setState(() {
      _message = _previewMessage;
      _expanded = false;
      _isFull = !_previewMessage.truncated;
      _error = '';
      _loadingMore = false;
      _partGroups = _buildGroups(_effectiveMessage.allParts);
    });
  }

  Future<void> _loadMoreChunks() async {
    if (_isFull || _loadingMore || !_isVisible) return;

    while (mounted && _isVisible) {
      final state = context.read<AppState>();
      final threadId = state.activeThreadId;
      final messageId = _message.id;
      final total = _message.totalChars;
      if (threadId == null || messageId == null || total == null) break;

      final offset = _message.content.runes.length;
      if (offset >= total) {
        setState(() {
          _isFull = true;
          _loadingMore = false;
        });
        break;
      }

      final token = _loadToken;
      setState(() => _loadingMore = true);
      try {
        final limit = _chunkSize(total, offset);
        final chunk = await state.api.getMessageChunk(
          threadId,
          messageId,
          offset: offset,
          limit: limit,
        );
        if (!mounted) return;

        if (_loadToken != token) {
          return;
        }

        final currentState = context.read<AppState>();
        if (currentState.activeThreadId != threadId ||
            _message.id != messageId) {
          setState(() => _loadingMore = false);
          return;
        }

        final currentLoaded = _message.content.runes.length;
        if (!_isVisible || currentLoaded != offset) {
          setState(() => _loadingMore = false);
          return;
        }

        if (chunk.content.isEmpty) {
          setState(() {
            _loadingMore = false;
            _isFull = true;
          });
          break;
        }

        setState(() {
          _message = _message.copyWith(
            content: _message.content + chunk.content,
            totalChars: chunk.totalChars ?? total,
          );
          _loadingMore = false;
          _error = '';
          _isFull =
              _message.content.runes.length >= (_message.totalChars ?? total);
          _partGroups = _buildGroups(_effectiveMessage.allParts);
        });
      } catch (e) {
        if (!mounted) return;
        if (_loadToken != token) {
          return;
        }
        final currentState = context.read<AppState>();
        if (currentState.activeThreadId != threadId ||
            _message.id != messageId) {
          setState(() => _loadingMore = false);
          return;
        }
        setState(() {
          _loadingMore = false;
          _error = '$e';
        });
        return;
      }
    }
  }

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
          groups.add(
            _PartGroup(
              type: 'thinking',
              thinkingItems: [_ThinkingItem(type: 'thinking', content: text)],
            ),
          );
        }
      } else if (part.type == 'tool_call') {
        final tool = part.toolCall;
        if (tool == null) continue;
        if (tool.kind == 'edit' || tool.kind == 'execute') {
          groups.add(_PartGroup(type: 'tool_call', tool: tool));
        } else if (groups.isNotEmpty && groups.last.type == 'thinking') {
          groups.last.thinkingItems.add(
            _ThinkingItem(type: 'tool_call', tool: tool),
          );
        } else {
          groups.add(
            _PartGroup(
              type: 'thinking',
              thinkingItems: [_ThinkingItem(type: 'tool_call', tool: tool)],
            ),
          );
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
    final displayText = stripPlanMarkup(text);
    if (role == 'assistant') {
      final highlighter = _syntaxHighlighter ?? SyntaxHighlighter(theme);
      return MarkdownBody(
        data: displayText,
        selectable: false,
        onTapLink: (txt, href, title) {
          if (href != null) context.read<AppState>().openLink(href);
        },
        extensionSet: markdown.ExtensionSet.gitHubFlavored,
        builders: {'pre': _PreBuilder(highlighter: highlighter)},
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
      text: displayText,
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
          _buildTextContent(context, group.content ?? '', _message.role),
        );
      } else if (group.type == 'tool_call') {
        final tool = group.tool;
        if (tool != null) {
          children.add(
            _ToolCallItem(key: ValueKey('tool-group-$i'), tool: tool),
          );
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

  Widget _buildAttachment(BuildContext context, Attachment a) {
    if (!a.isImage || a.isPathRef || a.isThreadRef) {
      return _attachmentChip(Theme.of(context), a);
    }
    final bytes = a.bytes;
    if (bytes != null && bytes.isNotEmpty) {
      return AttachmentThumb(
        bytes: bytes,
        filename: a.filename,
        onTap: () => showAttachmentPreview(
          context,
          bytes: bytes,
          filename: a.filename,
        ),
      );
    }
    final messageId = _message.id;
    final index = a.index;
    if (messageId == null || index == null) {
      return _attachmentChip(Theme.of(context), a);
    }
    return _RemoteAttachmentThumb(
      key: ValueKey('attachment-thumb-$messageId-$index'),
      attachment: a,
      threadId: widget.threadId,
      messageId: messageId,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final message = _message;
    final l = l10n(context);
    final assistantLabel = message.model.isNotEmpty
        ? message.model
        : l.messageRoleAssistant;
    final (icon, label, avatarBg, avatarFg) = switch (message.role) {
      'user' => (
        Icons.person_outline,
        l.messageRoleYou,
        theme.colorScheme.primaryContainer,
        theme.colorScheme.onPrimaryContainer,
      ),
      'assistant' => (
        Icons.smart_toy_outlined,
        assistantLabel,
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

    final groups = _partGroups;
    final showLoading =
        message.role == 'assistant' &&
        message.content.isEmpty &&
        groups.isEmpty;
    final showShowMore = _shouldCollapse;
    final showLoadingMore = _isAssistant && _message.truncated && _loadingMore;
    final showLoadError =
        _isAssistant &&
        _message.truncated &&
        _error.isNotEmpty &&
        !_loadingMore;

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
                  SelectionArea(
                    child: _MessageContextMenu(
                      message: _message,
                      child: _buildPartWidgets(context, groups),
                    ),
                  ),
                if (showLoading)
                  Text(
                    l10n(context).messageLoading,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                if (showShowMore) ...[
                  const SizedBox(height: 4),
                  TextButton(
                    onPressed: () => setState(() {
                      _expanded = true;
                      _partGroups = _buildGroups(_effectiveMessage.allParts);
                    }),
                    child: Text(l10n(context).showMore),
                  ),
                ],
                if (showLoadingMore) ...[
                  const SizedBox(height: 4),
                  Text(
                    l10n(context).loadingMore,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                if (showLoadError) ...[
                  const SizedBox(height: 4),
                  Text(
                    _error,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ],
                if (message.attachments != null &&
                    message.attachments!.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final a in message.attachments!)
                        _buildAttachment(context, a),
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

class _MessageContextMenu extends StatelessWidget {
  final Message message;
  final Widget child;

  const _MessageContextMenu({
    required this.message,
    required this.child,
  });

  static final _mrUrlPattern = RegExp(
    r'https?://[^\s<>"`{}|\\^`\[\]]+?/-/merge_requests/\d+',
    caseSensitive: false,
  );

  LinkedMergeRequestRef? get _firstLink {
    for (final match in _mrUrlPattern.allMatches(message.content)) {
      final ref = LinkedMergeRequestRef.tryParse(match.group(0)!);
      if (ref != null) return ref;
    }
    return null;
  }

  bool _isLinkedToActiveThread(LinkedMergeRequestRef ref, AppState state) {
    final thread = state.activeThreadDetail?.thread;
    final linked = thread?.linkedMr;
    if (linked == null) return false;
    return linked.hostname == ref.hostname &&
        linked.projectPath == ref.projectPath &&
        linked.iid == ref.iid;
  }

  void _show(BuildContext context, Offset position) {
    final ref = _firstLink;
    if (ref == null) return;

    final state = context.read<AppState>();
    final l = l10n(context);
    final isLinked = _isLinkedToActiveThread(ref, state);
    final threadId = state.activeThreadId;
    final renderBox = context.findRenderObject() as RenderBox?;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (renderBox == null || overlay == null || overlay.size.isEmpty) return;

    final global = renderBox.localToGlobal(position);
    final relative = RelativeRect.fromSize(
      Rect.fromPoints(global, global.translate(2, 2)),
      overlay.size,
    );

    showMenu(
      context: context,
      position: relative,
      items: [
        PopupMenuItem(
          child: Text(l.openLink),
          onTap: () => state.openLink(ref.webUrl),
        ),
        PopupMenuItem(
          child: Text(l.copyLink),
          onTap: () async {
            await Clipboard.setData(ClipboardData(text: ref.webUrl));
          },
        ),
        if (threadId != null)
          PopupMenuItem(
            child: Text(
              isLinked ? l.unlinkFromThread : l.linkToThread,
            ),
            onTap: () {
              if (isLinked) {
                state.unlinkThreadLinkedMr(threadId);
              } else {
                state.setThreadLinkedMr(threadId, ref.webUrl);
              }
            },
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onSecondaryTapUp: (details) => _show(context, details.localPosition),
      onLongPressStart: (details) => _show(context, details.localPosition),
      child: child,
    );
  }
}

/// Filename chip used for non-image attachments and as the fallback while an
/// image blob is still loading or cannot be fetched.
Widget _attachmentChip(ThemeData theme, Attachment a) {
  return Chip(
    avatar: Icon(
      a.isThreadRef
          ? Icons.chat_bubble_outline
          : a.isPathRef
          ? (a.isDir
                ? Icons.folder_outlined
                : Icons.insert_drive_file_outlined)
          : Icons.attach_file,
      size: 14,
    ),
    label: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360),
      child: Text(a.filename, maxLines: 1, overflow: TextOverflow.ellipsis),
    ),
    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
    visualDensity: VisualDensity.compact,
    backgroundColor: theme.colorScheme.surfaceContainerHigh,
  );
}

/// Image attachment tile that pulls the stored blob from the backend. Shows
/// the filename chip until the bytes arrive, and permanently when the request
/// fails (e.g. messages sent before attachments were persisted).
class _RemoteAttachmentThumb extends StatefulWidget {
  final Attachment attachment;
  final String threadId;
  final int messageId;

  const _RemoteAttachmentThumb({
    super.key,
    required this.attachment,
    required this.threadId,
    required this.messageId,
  });

  @override
  State<_RemoteAttachmentThumb> createState() => _RemoteAttachmentThumbState();
}

class _RemoteAttachmentThumbState extends State<_RemoteAttachmentThumb> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final att = await context.read<AppState>().api.getMessageAttachment(
        widget.threadId,
        widget.messageId,
        widget.attachment.index!,
      );
      if (!mounted || att.bytes.isEmpty) return;
      setState(() => _bytes = att.bytes);
    } catch (_) {
      // The chip stays; missing or unreadable blobs are not fatal.
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes == null) {
      return _attachmentChip(Theme.of(context), widget.attachment);
    }
    return AttachmentThumb(
      bytes: bytes,
      filename: widget.attachment.filename,
      onTap: () => showAttachmentPreview(
        context,
        bytes: bytes,
        filename: widget.attachment.filename,
      ),
    );
  }
}
