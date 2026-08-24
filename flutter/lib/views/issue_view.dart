import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart' hide SyntaxHighlighter;
import 'package:markdown/markdown.dart' as markdown;

import '../l10n/l10n.dart';
import '../issue/issue_models.dart';
import '../merge_request/merge_request_models.dart';
import '../state/async_value.dart';
import '../utils/link_opener.dart';
import 'markdown_rendering.dart';
import 'syntax_highlighter.dart';

/// Native, tabbed view of a GitLab issue.
///
/// Decoupled from data loading: it receives the current [AsyncValue] and
/// callbacks, so it can be used with any [IssueProvider].
class IssueView extends StatelessWidget {
  final AsyncValue<IssueDetail> detail;
  final String? url;
  final VoidCallback? onRetry;
  final ValueChanged<String>? onLinkTap;

  const IssueView({
    super.key,
    required this.detail,
    this.url,
    this.onRetry,
    this.onLinkTap,
  });

  @override
  Widget build(BuildContext context) {
    if (detail.isReady) {
      return _IssueBody(
        detail: detail.valueOrNull!,
        url: url,
        onLinkTap: onLinkTap,
      );
    }
    if (detail.isLoading) return const Center(child: CircularProgressIndicator());
    if (detail.isError) {
      return _ErrorView(error: '${detail.errorOrNull}', onRetry: onRetry);
    }
    return const SizedBox.shrink();
  }
}

class _IssueBody extends StatefulWidget {
  final IssueDetail detail;
  final String? url;
  final ValueChanged<String>? onLinkTap;

  const _IssueBody({
    required this.detail,
    this.url,
    this.onLinkTap,
  });

  @override
  State<_IssueBody> createState() => _IssueBodyState();
}

class _IssueBodyState extends State<_IssueBody>
    with TickerProviderStateMixin {
  late final _tabController = TabController(length: 2, vsync: this);

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final detail = widget.detail;
    final stateChip = _stateChip(context, detail);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(
          detail: detail,
          url: widget.url,
          stateChip: stateChip,
          onLinkTap: widget.onLinkTap,
        ),
        const SizedBox(height: 8),
        TabBar(
          controller: _tabController,
          tabs: [
            Tab(text: l10n(context).overview),
            Tab(text:
                '${l10n(context).issueComments} (${detail.comments.length})'),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              _OverviewTab(detail: detail, onLinkTap: widget.onLinkTap),
              _CommentsTab(
                comments: detail.comments,
                onLinkTap: widget.onLinkTap,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  final IssueDetail detail;
  final String? url;
  final Widget? stateChip;
  final ValueChanged<String>? onLinkTap;

  const _Header({
    required this.detail,
    this.url,
    this.stateChip,
    this.onLinkTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final author = detail.author;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                detail.title,
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w600),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (stateChip != null) ...[
              const SizedBox(width: 12),
              stateChip!,
            ],
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Text(
              '#${detail.iid}',
              style: theme.textTheme.labelMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(width: 12),
            if (author != null)
              Text(
                '@${author.username}',
                style: theme.textTheme.labelMedium,
              ),
            const Spacer(),
            if (url != null && isOpenableLink(url))
              IconButton(
                tooltip: l10n(context).issueOpenInBrowser,
                icon: const Icon(Icons.open_in_new, size: 18),
                onPressed: () => onLinkTap?.call(url!),
              ),
          ],
        ),
      ],
    );
  }
}

Widget? _stateChip(BuildContext context, IssueDetail detail) {
  final theme = Theme.of(context);
  final color = detail.isOpen
      ? theme.colorScheme.primary
      : (detail.isClosed
          ? theme.colorScheme.error
          : theme.colorScheme.onSurfaceVariant);

  if (detail.state.isEmpty) return null;

  return Chip(
    label: Text(
      detail.isOpen ? l10n(context).issueOpen : l10n(context).issueClosed,
      style: TextStyle(
        color: color,
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
    ),
    backgroundColor: color.withValues(alpha: 0.12),
    side: BorderSide.none,
    padding: EdgeInsets.zero,
    visualDensity: VisualDensity.compact,
  );
}

class _OverviewTab extends StatelessWidget {
  final IssueDetail detail;
  final ValueChanged<String>? onLinkTap;

  const _OverviewTab({required this.detail, this.onLinkTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final highlighter = SyntaxHighlighter(theme);

    final description = detail.description.isEmpty
        ? _NoDescription()
        : MarkdownBody(
            data: detail.description,
            selectable: false,
            onTapLink: (txt, href, title) {
              if (href != null) onLinkTap?.call(href);
            },
            extensionSet: markdown.ExtensionSet.gitHubFlavored,
            builders: {'pre': PreBuilder(highlighter: highlighter)},
            styleSheet: markdownStyleSheet(theme),
          );

    return SingleChildScrollView(
      padding: const EdgeInsets.only(top: 16, bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _MetaRow(detail: detail),
          if (detail.labels.isNotEmpty) ...[
            const SizedBox(height: 12),
            _LabelsRow(labels: detail.labels),
          ],
          const SizedBox(height: 16),
          description,
        ],
      ),
    );
  }
}

class _MetaRow extends StatelessWidget {
  final IssueDetail detail;

  const _MetaRow({required this.detail});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final parts = <String>[];
    if (detail.createdAt.isNotEmpty) parts.add(detail.createdAt);
    if (detail.updatedAt.isNotEmpty && detail.updatedAt != detail.createdAt) {
      parts.add('updated ${detail.updatedAt}');
    }
    if (detail.milestone != null && detail.milestone!.isNotEmpty) {
      parts.add('milestone: ${detail.milestone}');
    }
    if (detail.assignees.isNotEmpty) {
      parts.add(
        'assigned to ${detail.assignees.map((a) => '@${a.username}').join(', ')}',
      );
    }

    if (parts.isEmpty) return const SizedBox.shrink();

    return Text(
      parts.join(' · '),
      style: theme.textTheme.labelSmall
          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
    );
  }
}

class _LabelsRow extends StatelessWidget {
  final List<String> labels;

  const _LabelsRow({required this.labels});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        Text(
          '${l10n(context).issueLabels}:',
          style: theme.textTheme.labelMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        for (final label in labels)
          Chip(
            label: Text(label, style: const TextStyle(fontSize: 11)),
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            side: BorderSide(color: theme.colorScheme.outlineVariant),
          ),
      ],
    );
  }
}

class _NoDescription extends StatelessWidget {
  const _NoDescription();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Text(
        l10n(context).issueNoDescription,
        style: theme.textTheme.bodyMedium
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }
}

class _CommentsTab extends StatelessWidget {
  final List<MergeRequestComment> comments;
  final ValueChanged<String>? onLinkTap;

  const _CommentsTab({
    required this.comments,
    this.onLinkTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (comments.isEmpty) {
      return Center(
        child: Text(
          l10n(context).noComments,
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.only(top: 8, bottom: 24),
      itemCount: comments.length,
      itemBuilder: (context, index) {
        final comment = comments[index];
        final author = comment.author;

        return Card(
          margin: const EdgeInsets.symmetric(vertical: 4),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (author != null)
                  Text(
                    '@${author.username}',
                    style: theme.textTheme.labelMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                if (comment.createdAt.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    comment.createdAt,
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
                const SizedBox(height: 8),
                MarkdownBody(
                  data: comment.system
                      ? htmlToMarkdown(comment.body)
                      : comment.body,
                  selectable: false,
                  onTapLink: (txt, href, title) {
                    if (href != null) onLinkTap?.call(href);
                  },
                  styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
                    p: comment.system
                        ? theme.textTheme.bodyMedium?.copyWith(
                            fontStyle: FontStyle.italic,
                            color: theme.colorScheme.onSurfaceVariant,
                            height: 1.4,
                          )
                        : theme.textTheme.bodyLarge?.copyWith(height: 1.4),
                    a: comment.system
                        ? theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.primary,
                            fontStyle: FontStyle.italic,
                          )
                        : null,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String error;
  final VoidCallback? onRetry;

  const _ErrorView({required this.error, this.onRetry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline,
                color: theme.colorScheme.error, size: 40),
            const SizedBox(height: 16),
            Text(
              error,
              textAlign: TextAlign.center,
              style: TextStyle(color: theme.colorScheme.error),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 16),
              FilledButton(onPressed: onRetry, child: Text(l10n(context).retry)),
            ],
          ],
        ),
      ),
    );
  }
}
