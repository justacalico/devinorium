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
        // File edits and command executions are rendered as standalone cards
        // outside the thinking block so the user can see them without expanding.
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
          _buildTextContent(context, group.content ?? '', widget.message.role),
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
    final message = widget.message;
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
