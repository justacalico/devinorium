part of '../thread_page.dart';

class _MessagesPanel extends StatelessWidget {
  final ThreadDetail? detail;
  final bool loading;
  final List<MessagePart> streamingParts;
  final int streamingDigest;
  final bool streamingThinkingActive;
  final bool sending;
  final ScrollController controller;
  final bool hasServer;
  const _MessagesPanel({
    required this.detail,
    required this.loading,
    required this.streamingParts,
    required this.streamingDigest,
    required this.streamingThinkingActive,
    required this.sending,
    required this.controller,
    required this.hasServer,
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
      if (!hasServer) {
        final state = context.read<AppState>();
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(48),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.cloud_off_outlined,
                  size: 48,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(height: 16),
                Text(
                  l10n(context).addServerFromSettingsPrompt,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                FilledButton.tonal(
                  onPressed: () => state.setPage(MainPage.settings),
                  child: Text(l10n(context).settings),
                ),
              ],
            ),
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
    final hasStreaming = sending && streamingParts.isNotEmpty;

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
        reverse: true,
        physics: const ClampingScrollPhysics(),
        padding: const EdgeInsets.symmetric(vertical: 24),
        addAutomaticKeepAlives: false,
        addRepaintBoundaries: true,
        scrollCacheExtent: const ScrollCacheExtent.pixels(200),
        itemCount: messages.length + (hasStreaming ? 1 : 0),
        itemBuilder: (context, index) {
          if (hasStreaming && index == 0) {
            return _MessageItem(
              key: const ValueKey('streaming'),
              message: Message(
                role: 'assistant',
                content: '',
                attachments: null,
                parts: streamingParts,
                partsDigest: streamingDigest,
                model: detail?.thread.model ?? '',
              ),
              threadId: detail!.thread.id,
              thinkingActive: streamingThinkingActive,
            );
          }
          final offset = hasStreaming ? 1 : 0;
          final message = messages[messages.length - 1 - (index - offset)];
          return _MessageItem(
            key: ValueKey(message.id ?? message.content),
            message: message,
            threadId: detail!.thread.id,
          );
        },
      ),
    );
  }
}
