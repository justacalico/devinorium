part of '../thread_page.dart';

/// A compact chip that links to the merge request associated with the active
/// thread's branch. Tapping it opens the MR in a new tab; long-press copies
/// the URL. Hidden when no MR is linked.
class LinkedMergeRequestChip extends StatelessWidget {
  final MergeRequestLink mr;
  const LinkedMergeRequestChip({super.key, required this.mr});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final draft = mr.draft;
    final label = draft ? 'Draft !${mr.iid}' : '!${mr.iid}';
    final tooltip = mr.title.isEmpty ? label : '$label: ${mr.title}';
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onLongPress: mr.webUrl.isEmpty
            ? null
            : () async {
                await Clipboard.setData(ClipboardData(text: mr.webUrl));
                if (context.mounted) {
                  showAppMessage(
                    context,
                    l10n(context).copiedToClipboard,
                    kind: MessageKind.success,
                    duration: const Duration(seconds: 1),
                  );
                }
              },
        onTap: mr.webUrl.isEmpty
            ? null
            : () => context.read<AppState>().openLink(mr.webUrl),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color:
                (draft
                        ? colorScheme.errorContainer
                        : colorScheme.secondaryContainer)
                    .withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: (draft ? colorScheme.error : colorScheme.secondary)
                  .withValues(alpha: 0.4),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                draft ? Icons.edit_note : Icons.merge,
                size: 14,
                color: draft
                    ? colorScheme.onErrorContainer
                    : colorScheme.onSecondaryContainer,
              ),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: draft
                      ? colorScheme.onErrorContainer
                      : colorScheme.onSecondaryContainer,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
