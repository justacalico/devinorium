part of '../thread_page.dart';

/// Inline action row under a message: copy, edit-and-resend for user
/// messages, regenerate for the last assistant reply.
class _MessageActions extends StatelessWidget {
  final Message message;
  final bool isLastMessage;
  final bool sending;

  const _MessageActions({
    required this.message,
    required this.isLastMessage,
    required this.sending,
  });

  bool get _canCopy => message.content.isNotEmpty;

  bool get _canEdit =>
      message.role == 'user' && message.id != null && !sending;

  bool get _canRegenerate =>
      (message.role == 'assistant' || message.role == 'error') &&
      message.id != null &&
      isLastMessage &&
      !sending;

  @override
  Widget build(BuildContext context) {
    if (!_canCopy && !_canEdit && !_canRegenerate) {
      return const SizedBox.shrink();
    }
    final l = l10n(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_canCopy)
          _MessageActionButton(
            icon: Icons.content_copy_outlined,
            tooltip: l.copyMessage,
            onTap: () => _copyMessage(context, message.content),
          ),
        if (_canEdit)
          _MessageActionButton(
            icon: Icons.edit_outlined,
            tooltip: l.editAndResend,
            onTap: () => _editAndResend(context, message),
          ),
        if (_canRegenerate)
          _MessageActionButton(
            icon: Icons.refresh,
            tooltip: l.regenerate,
            onTap: () => context.read<AppState>().resendMessage(message),
          ),
      ],
    );
  }
}

class _MessageActionButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _MessageActionButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(
            icon,
            size: 15,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

void _copyMessage(BuildContext context, String text) {
  final l = l10n(context);
  unawaited(
    Clipboard.setData(ClipboardData(text: text)).then((_) {
      if (context.mounted) {
        showAppMessage(context, l.copiedToClipboard, kind: MessageKind.info);
      }
    }),
  );
}

Future<void> _editAndResend(BuildContext context, Message message) async {
  final submitted = await showDialog<String>(
    context: context,
    builder: (_) => _EditMessageDialog(initialText: message.content),
  );
  final text = submitted?.trim() ?? '';
  if (text.isEmpty || !context.mounted) return;
  unawaited(
    context.read<AppState>().resendMessage(message, editedPrompt: text),
  );
}

class _EditMessageDialog extends StatefulWidget {
  final String initialText;

  const _EditMessageDialog({required this.initialText});

  @override
  State<_EditMessageDialog> createState() => _EditMessageDialogState();
}

class _EditMessageDialogState extends State<_EditMessageDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = l10n(context);
    return AlertDialog(
      title: Text(l.editMessageTitle),
      content: SizedBox(
        width: 480,
        child: TextField(
          controller: _controller,
          autofocus: true,
          minLines: 1,
          maxLines: 10,
          textInputAction: TextInputAction.newline,
          decoration: InputDecoration(hintText: l.composerHint),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text),
          child: Text(l.resend),
        ),
      ],
    );
  }
}
