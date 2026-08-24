import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../merge_request/merge_request_models.dart';

/// Buttons that change the state of a merge request.
///
/// Owns the in-flight and error state so a failed action does not wipe out the
/// loaded merge request.
class MergeRequestActionBar extends StatefulWidget {
  final MergeRequestDetail detail;
  final Future<void> Function(MergeRequestAction action) onAction;

  const MergeRequestActionBar({
    super.key,
    required this.detail,
    required this.onAction,
  });

  @override
  State<MergeRequestActionBar> createState() => _MergeRequestActionBarState();
}

class _MergeRequestActionBarState extends State<MergeRequestActionBar> {
  MergeRequestAction? _pending;
  String? _error;

  @override
  void didUpdateWidget(MergeRequestActionBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A reload means the failure the user saw is no longer current.
    if (oldWidget.detail != widget.detail) _error = null;
  }

  Future<void> _run(MergeRequestAction action) async {
    setState(() {
      _pending = action;
      _error = null;
    });
    try {
      await widget.onAction(action);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _pending = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final detail = widget.detail;
    if (detail.isMerged || detail.state.isEmpty) return const SizedBox.shrink();

    final busy = _pending != null;
    final latest = detail.pipelines.isNotEmpty ? detail.pipelines.first : null;
    final showAutoMerge = detail.canMerge &&
        !detail.mergeWhenPipelineSucceeds &&
        (latest?.isActive ?? false);

    final buttons = <Widget>[
      if (detail.isOpen)
        FilledButton.icon(
          onPressed: busy || !detail.canMerge
              ? null
              : () => _run(MergeRequestAction.merge),
          icon: const Icon(Icons.merge, size: 18),
          label: Text(l10n(context).merge),
        ),
      if (showAutoMerge)
        OutlinedButton.icon(
          onPressed:
              busy ? null : () => _run(MergeRequestAction.mergeWhenPipelineSucceeds),
          icon: const Icon(Icons.schedule, size: 18),
          label: Text(l10n(context).mergeWhenPipelineSucceeds),
        ),
      if (detail.isOpen)
        TextButton.icon(
          onPressed: busy ? null : () => _run(MergeRequestAction.close),
          icon: const Icon(Icons.block, size: 18),
          label: Text(l10n(context).closeMergeRequest),
        ),
      if (detail.isClosed)
        FilledButton.icon(
          onPressed: busy ? null : () => _run(MergeRequestAction.reopen),
          icon: const Icon(Icons.restart_alt, size: 18),
          label: Text(l10n(context).reopenMergeRequest),
        ),
    ];

    if (buttons.isEmpty) return const SizedBox.shrink();

    final hint = _hint(context, detail);

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Wrap(spacing: 8, runSpacing: 8, children: buttons),
              ),
              if (busy) ...[
                const SizedBox(width: 12),
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                Text(
                  l10n(context).mergeRequestWorking,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ],
          ),
          if (hint != null) ...[
            const SizedBox(height: 6),
            Text(
              hint,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 6),
            Text(
              _error!,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.error),
            ),
          ],
        ],
      ),
    );
  }

  String? _hint(BuildContext context, MergeRequestDetail detail) {
    if (detail.isOpen && detail.draft) {
      return l10n(context).mergeRequestDraftBlocked;
    }
    if (detail.isOpen && detail.hasConflicts) {
      return l10n(context).mergeRequestConflictsBlocked;
    }
    if (detail.mergeWhenPipelineSucceeds) {
      return l10n(context).mergeRequestAutoMergeSet;
    }
    return null;
  }
}
