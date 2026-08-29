part of '../thread_page.dart';

class _MessageItem extends StatefulWidget {
  final Message message;
  final bool thinkingActive;
  const _MessageItem({
    super.key,
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
  bool _expanded = false;
  bool _isFull = false;
  bool _loadingMore = false;
  String _error = '';
  bool _isVisible = false;
  ScrollPosition? _scrollPosition;
  bool _visibilityCheckScheduled = false;

  @override
  void initState() {
    super.initState();
    _previewMessage = widget.message;
    _message = widget.message;
    _isFull = !_message.truncated;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final position = Scrollable.maybeOf(context)?.position;
    if (position != _scrollPosition) {
      _scrollPosition?.removeListener(_onScroll);
      _scrollPosition = position;
      _scrollPosition?.addListener(_onScroll);
    }
    _scheduleVisibilityCheck();
  }

  @override
  void didUpdateWidget(covariant _MessageItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    final incoming = widget.message;
    if (incoming.id != _previewMessage.id ||
        incoming.truncated != _previewMessage.truncated ||
        incoming != _previewMessage) {
      _previewMessage = incoming;
      _message = incoming;
      _expanded = false;
      _isFull = !incoming.truncated;
      _loadingMore = false;
      _error = '';
      if (_isVisible && !_isFull) {
        _loadMoreChunks();
      }
    }
  }

  @override
  void dispose() {
    _scrollPosition?.removeListener(_onScroll);
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

  void _onScroll() => _scheduleVisibilityCheck();

  void _scheduleVisibilityCheck() {
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
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || box.size.isEmpty) return;

    final viewport = RenderAbstractViewport.of(box) as RenderBox?;
    if (viewport == null || viewport.size.isEmpty) return;

    final itemOffset = box.localToGlobal(Offset.zero, ancestor: viewport);
    final itemRect = itemOffset & box.size;
    final viewportRect = Offset.zero & viewport.size;
    final isVisible =
        itemRect.overlaps(viewportRect.inflate(_visibilityMargin));

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
    if (_loadingMore) _loadingMore = false;
    if (_message != _previewMessage) {
      if (!mounted) return;
      setState(() {
        _message = _previewMessage;
        _isFull = !_previewMessage.truncated;
        _error = '';
      });
    }
  }

  Future<void> _loadMoreChunks() async {
    if (_isFull || _loadingMore || !_isVisible) return;
    final state = context.read<AppState>();
    final threadId = state.activeThreadId;
    final messageId = _message.id;
    final total = _message.totalChars;
    if (threadId == null || messageId == null || total == null) return;

    final offset = _message.content.runes.length;
    if (offset >= total) {
      if (mounted) setState(() => _isFull = true);
      return;
    }

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

      final currentLoaded = _message.content.runes.length;
      if (!_isVisible || currentLoaded != offset) {
        setState(() => _loadingMore = false);
        return;
      }

      setState(() {
        _message = _message.copyWith(
          content: _message.content + chunk.content,
          totalChars: chunk.totalChars ?? total,
        );
        _loadingMore = false;
        _error = '';
        _isFull = _message.content.runes.length >= (_message.totalChars ?? total);
      });

      if (!_isFull && _isVisible) {
        await _loadMoreChunks();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingMore = false;
        _error = '$e';
      });
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
      final highlighter = SyntaxHighlighter(theme);
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

    final groups = _buildGroups(_effectiveMessage.allParts);
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
                  SelectionArea(child: _buildPartWidgets(context, groups)),
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
                    onPressed: () => setState(() => _expanded = true),
                    child: const Text('Show more'),
                  ),
                ],
                if (showLoadingMore) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Loading more…',
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
