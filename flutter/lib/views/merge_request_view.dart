import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart'
    hide SyntaxHighlighter;
import 'package:markdown/markdown.dart' as markdown;

import '../l10n/l10n.dart';
import '../merge_request/merge_request_models.dart';
import '../state/async_value.dart';
import '../utils/link_opener.dart';
import 'markdown_rendering.dart';
import 'merge_request_action_bar.dart';
import 'syntax_highlighter.dart';

/// Native, tabbed view of a merge request.
///
/// Decoupled from data loading: it receives the current [AsyncValue] and
/// callbacks, so it can be used with any [MergeRequestProvider].
class MergeRequestView extends StatelessWidget {
  final AsyncValue<MergeRequestDetail> detail;
  final String? url;
  final VoidCallback? onRetry;
  final ValueChanged<String>? onLinkTap;

  /// Loads CI/CD jobs for a pipeline. When null, pipeline tiles are not
  /// expandable and only the open-in-browser action is available.
  final PipelineJobsLoader? onLoadJobs;

  /// Called when a CI/CD job row is tapped. When null, tappable rows fall back
  /// to opening the job in the browser.
  final PipelineJobTap? onJobTap;

  /// Applies a state change to the merge request. When null, no action
  /// buttons are shown.
  final Future<void> Function(MergeRequestAction action)? onAction;

  const MergeRequestView({
    super.key,
    required this.detail,
    this.url,
    this.onRetry,
    this.onLinkTap,
    this.onLoadJobs,
    this.onJobTap,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    if (detail.isReady) {
      return _MergeRequestBody(
        detail: detail.valueOrNull!,
        url: url,
        onLinkTap: onLinkTap,
        onLoadJobs: onLoadJobs,
        onJobTap: onJobTap,
        onAction: onAction,
      );
    }
    if (detail.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (detail.isError) {
      return _ErrorView(error: '${detail.errorOrNull}', onRetry: onRetry);
    }
    return const SizedBox.shrink();
  }
}

class _MergeRequestBody extends StatefulWidget {
  final MergeRequestDetail detail;
  final String? url;
  final ValueChanged<String>? onLinkTap;
  final PipelineJobsLoader? onLoadJobs;
  final PipelineJobTap? onJobTap;
  final Future<void> Function(MergeRequestAction action)? onAction;

  const _MergeRequestBody({
    required this.detail,
    this.url,
    this.onLinkTap,
    this.onLoadJobs,
    this.onJobTap,
    this.onAction,
  });

  @override
  State<_MergeRequestBody> createState() => _MergeRequestBodyState();
}

class _MergeRequestBodyState extends State<_MergeRequestBody>
    with TickerProviderStateMixin {
  late final _tabController = TabController(length: 4, vsync: this);

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
        if (widget.onAction != null)
          MergeRequestActionBar(detail: detail, onAction: widget.onAction!),
        const SizedBox(height: 8),
        TabBar(
          controller: _tabController,
          tabs: [
            Tab(text: l10n(context).overview),
            Tab(text: '${l10n(context).changes} (${detail.changes.length})'),
            Tab(text: '${l10n(context).comments} (${detail.comments.length})'),
            Tab(
              text: '${l10n(context).pipelines} (${detail.pipelines.length})',
            ),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              _OverviewTab(
                detail: detail,
                onLinkTap: widget.onLinkTap,
                onLoadJobs: widget.onLoadJobs,
                onJobTap: widget.onJobTap,
              ),
              _ChangesTab(changes: detail.changes),
              _CommentsTab(
                comments: detail.comments,
                onLinkTap: widget.onLinkTap,
              ),
              _PipelinesTab(
                pipelines: detail.pipelines,
                onLinkTap: widget.onLinkTap,
                onLoadJobs: widget.onLoadJobs,
                onJobTap: widget.onJobTap,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  final MergeRequestDetail detail;
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
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (stateChip != null) ...[const SizedBox(width: 12), stateChip!],
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Text(
              'MR !${detail.iid}',
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 12),
            Text(
              detail.branches,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(width: 12),
            if (author != null)
              Text('@${author.username}', style: theme.textTheme.labelMedium),
            const Spacer(),
            if (url != null && isOpenableLink(url))
              IconButton(
                tooltip: l10n(context).openInBrowser,
                icon: const Icon(Icons.open_in_new, size: 18),
                onPressed: () => onLinkTap?.call(url!),
              ),
          ],
        ),
      ],
    );
  }
}

Widget? _stateChip(BuildContext context, MergeRequestDetail detail) {
  final theme = Theme.of(context);
  final color = switch (detail.state) {
    'opened' || 'open' => theme.colorScheme.primary,
    'merged' => Colors.purple,
    'closed' => theme.colorScheme.error,
    _ => theme.colorScheme.onSurfaceVariant,
  };

  if (detail.state.isEmpty) return null;

  return Chip(
    label: Text(
      detail.draft && detail.isOpen
          ? '${l10n(context).draft} · ${detail.state}'
          : detail.state,
      style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600),
    ),
    backgroundColor: color.withValues(alpha: 0.12),
    side: BorderSide.none,
    padding: EdgeInsets.zero,
    visualDensity: VisualDensity.compact,
  );
}

class _OverviewTab extends StatelessWidget {
  final MergeRequestDetail detail;
  final ValueChanged<String>? onLinkTap;
  final PipelineJobsLoader? onLoadJobs;
  final PipelineJobTap? onJobTap;

  const _OverviewTab({
    required this.detail,
    this.onLinkTap,
    this.onLoadJobs,
    this.onJobTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final latestPipeline = detail.pipelines.isNotEmpty
        ? detail.pipelines.first
        : null;

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
          if (latestPipeline != null && latestPipeline.isPresent) ...[
            _PipelineTile(
              key: ValueKey(latestPipeline.id),
              pipeline: latestPipeline,
              onLinkTap: onLinkTap,
              onLoadJobs: onLoadJobs,
              onJobTap: onJobTap,
              margin: EdgeInsets.zero,
            ),
            const SizedBox(height: 16),
          ],
          description,
        ],
      ),
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
        l10n(context).noDescription,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _PipelineTile extends StatefulWidget {
  final MergeRequestPipeline pipeline;
  final ValueChanged<String>? onLinkTap;
  final PipelineJobsLoader? onLoadJobs;
  final PipelineJobTap? onJobTap;
  final EdgeInsetsGeometry margin;

  const _PipelineTile({
    super.key,
    required this.pipeline,
    this.onLinkTap,
    this.onLoadJobs,
    this.onJobTap,
    this.margin = const EdgeInsets.symmetric(vertical: 4),
  });

  @override
  State<_PipelineTile> createState() => _PipelineTileState();
}

class _PipelineTileState extends State<_PipelineTile> {
  bool _expanded = false;
  bool _loading = false;
  List<MergeRequestPipelineJob>? _jobs;
  Object? _error;
  int _requestGeneration = 0;

  bool get _canExpand => widget.onLoadJobs != null && widget.pipeline.id > 0;

  void _toggle() {
    if (!_canExpand) {
      _openPipeline();
      return;
    }

    final expanding = !_expanded;
    setState(() {
      _expanded = expanding;
      if (!expanding) {
        _jobs = null;
        _error = null;
      }
    });

    if (expanding && _jobs == null && _error == null) {
      _loadJobs();
    }
  }

  void _openPipeline() {
    if (widget.pipeline.webUrl.isNotEmpty &&
        isOpenableLink(widget.pipeline.webUrl)) {
      widget.onLinkTap?.call(widget.pipeline.webUrl);
    }
  }

  void _retry() {
    _loadJobs();
  }

  Future<void> _loadJobs() async {
    if (_loading) return;
    final generation = ++_requestGeneration;
    setState(() {
      _loading = true;
      _error = null;
      _jobs = null;
    });

    try {
      final jobs = await widget.onLoadJobs!(widget.pipeline);
      if (!mounted || generation != _requestGeneration) return;
      setState(() {
        _jobs = jobs;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || generation != _requestGeneration) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  @override
  void didUpdateWidget(covariant _PipelineTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.pipeline.id != oldWidget.pipeline.id) {
      _requestGeneration++;
      _expanded = false;
      _loading = false;
      _jobs = null;
      _error = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = _pipelineColor(theme, widget.pipeline.status);
    final openable =
        widget.pipeline.webUrl.isNotEmpty &&
        isOpenableLink(widget.pipeline.webUrl);

    final trailingChildren = <Widget>[];
    if (openable) {
      trailingChildren.add(
        IconButton(
          icon: const Icon(Icons.open_in_new, size: 18),
          tooltip: l10n(context).openInBrowser,
          onPressed: _openPipeline,
        ),
      );
    }
    if (_canExpand) {
      if (trailingChildren.isNotEmpty) {
        trailingChildren.add(const SizedBox(width: 4));
      }
      trailingChildren.add(
        Icon(
          _expanded ? Icons.expand_less : Icons.expand_more,
          size: 18,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }

    final subtitleParts = [
      widget.pipeline.status,
      if (widget.pipeline.createdAt.isNotEmpty) widget.pipeline.createdAt,
    ];

    return Card(
      margin: widget.margin,
      child: InkWell(
        onTap: _canExpand || openable ? _toggle : null,
        borderRadius: BorderRadius.circular(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              leading: Icon(
                _pipelineIcon(widget.pipeline.status),
                color: color,
              ),
              title: Text(
                widget.pipeline.name.isNotEmpty
                    ? widget.pipeline.name
                    : widget.pipeline.status,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                subtitleParts.join(' · '),
                style: theme.textTheme.bodySmall?.copyWith(color: color),
              ),
              trailing: trailingChildren.isNotEmpty
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: trailingChildren,
                    )
                  : null,
            ),
            if (_expanded) _buildJobs(context),
          ],
        ),
      ),
    );
  }

  Widget _buildJobs(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    final error = _error;
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '$error',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
            TextButton(onPressed: _retry, child: Text(l10n(context).retry)),
          ],
        ),
      );
    }

    final jobs = _jobs ?? [];
    if (jobs.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Text(
          l10n(context).noJobs,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      child: _PipelineJobsList(
        jobs: jobs,
        onLinkTap: widget.onLinkTap,
        onJobTap: widget.onJobTap,
      ),
    );
  }
}

class _PipelineJobsList extends StatelessWidget {
  final List<MergeRequestPipelineJob> jobs;
  final ValueChanged<String>? onLinkTap;
  final PipelineJobTap? onJobTap;

  const _PipelineJobsList({required this.jobs, this.onLinkTap, this.onJobTap});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          children: jobs
              .map(
                (job) => _PipelineJobRow(
                  job: job,
                  onLinkTap: onLinkTap,
                  onJobTap: onJobTap,
                ),
              )
              .toList(),
        ),
      ),
    );
  }
}

class _PipelineJobRow extends StatelessWidget {
  final MergeRequestPipelineJob job;
  final ValueChanged<String>? onLinkTap;
  final PipelineJobTap? onJobTap;

  const _PipelineJobRow({required this.job, this.onLinkTap, this.onJobTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = _pipelineColor(theme, job.status);
    final openable = job.webUrl.isNotEmpty && isOpenableLink(job.webUrl);

    final subtitleParts = [job.status, if (job.stage.isNotEmpty) job.stage];

    return ListTile(
      dense: true,
      leading: Icon(_pipelineIcon(job.status), color: color, size: 20),
      title: Text(
        job.name.isNotEmpty ? job.name : job.status,
        style: theme.textTheme.bodyMedium?.copyWith(
          fontWeight: FontWeight.w500,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        subtitleParts.join(' · '),
        style: theme.textTheme.bodySmall?.copyWith(color: color),
      ),
      trailing: openable
          ? IconButton(
              icon: const Icon(Icons.open_in_new, size: 18),
              tooltip: l10n(context).openInBrowser,
              onPressed: () => onLinkTap?.call(job.webUrl),
            )
          : null,
      onTap: () => _onTap(context),
    );
  }

  void _onTap(BuildContext context) {
    if (onJobTap != null && job.id > 0) {
      onJobTap!(job);
      return;
    }
    if (job.webUrl.isNotEmpty && isOpenableLink(job.webUrl)) {
      onLinkTap?.call(job.webUrl);
    }
  }
}

Color _pipelineColor(ThemeData theme, String status) {
  final lower = status.toLowerCase();
  if (lower == 'success') return Colors.green;
  if (lower == 'failed' || lower == 'failure') return theme.colorScheme.error;
  if (lower == 'running') return theme.colorScheme.primary;
  if (lower == 'pending' ||
      lower == 'created' ||
      lower == 'waiting_for_resource') {
    return Colors.orange;
  }
  return theme.colorScheme.onSurfaceVariant;
}

IconData _pipelineIcon(String status) {
  final lower = status.toLowerCase();
  if (lower == 'success') return Icons.check_circle;
  if (lower == 'failed' || lower == 'failure') return Icons.error;
  if (lower == 'running') return Icons.play_circle;
  if (lower == 'pending' || lower == 'created') return Icons.pending;
  if (lower == 'canceled' || lower == 'skipped') return Icons.cancel;
  return Icons.play_circle_outline;
}

class _PipelinesTab extends StatelessWidget {
  final List<MergeRequestPipeline> pipelines;
  final ValueChanged<String>? onLinkTap;
  final PipelineJobsLoader? onLoadJobs;
  final PipelineJobTap? onJobTap;

  const _PipelinesTab({
    required this.pipelines,
    this.onLinkTap,
    this.onLoadJobs,
    this.onJobTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (pipelines.isEmpty) {
      return Center(
        child: Text(
          l10n(context).noPipelines,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.only(top: 8, bottom: 24),
      itemCount: pipelines.length,
      itemBuilder: (context, index) {
        final pipeline = pipelines[index];
        return _PipelineTile(
          key: ValueKey(pipeline.id),
          pipeline: pipeline,
          onLinkTap: onLinkTap,
          onLoadJobs: onLoadJobs,
          onJobTap: onJobTap,
        );
      },
    );
  }
}

class _ChangesTab extends StatefulWidget {
  final List<MergeRequestChange> changes;

  const _ChangesTab({required this.changes});

  @override
  State<_ChangesTab> createState() => _ChangesTabState();
}

class _ChangesTabState extends State<_ChangesTab> {
  int? _expanded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (widget.changes.isEmpty) {
      return Center(
        child: Text(
          l10n(context).noChanges,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.only(top: 8, bottom: 24),
      itemCount: widget.changes.length,
      itemBuilder: (context, index) {
        final change = widget.changes[index];
        final isExpanded = _expanded == index;
        return Card(
          margin: const EdgeInsets.symmetric(vertical: 4),
          child: InkWell(
            onTap: () => setState(() => _expanded = isExpanded ? null : index),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      _changeIcon(change),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          change.displayPath,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w500,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Icon(
                        isExpanded ? Icons.expand_less : Icons.expand_more,
                        size: 18,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ],
                  ),
                  if (isExpanded && change.diff.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    _DiffView(diff: change.diff),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _changeIcon(MergeRequestChange change) {
    if (change.newFile) {
      return const Icon(Icons.add, size: 18, color: Colors.green);
    }
    if (change.deletedFile) {
      return const Icon(Icons.remove, size: 18, color: Colors.red);
    }
    if (change.renamedFile) {
      return const Icon(Icons.drive_file_rename_outline, size: 18);
    }
    return const Icon(Icons.edit, size: 18);
  }
}

class _CommentsTab extends StatelessWidget {
  final List<MergeRequestComment> comments;
  final ValueChanged<String>? onLinkTap;

  const _CommentsTab({required this.comments, this.onLinkTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (comments.isEmpty) {
      return Center(
        child: Text(
          l10n(context).noComments,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
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
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                if (comment.createdAt.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    comment.createdAt,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
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

class _DiffView extends StatelessWidget {
  final String diff;

  const _DiffView({required this.diff});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lines = diff.split('\n');

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: lines.map((line) => _diffLine(line, theme)).toList(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _diffLine(String line, ThemeData theme) {
    Color color;
    if (line.startsWith('+')) {
      color = Colors.green;
    } else if (line.startsWith('-')) {
      color = Colors.red;
    } else if (line.startsWith('@@') ||
        line.startsWith('---') ||
        line.startsWith('+++') ||
        line.startsWith('diff ') ||
        line.startsWith('index ')) {
      color = theme.colorScheme.primary;
    } else {
      color = theme.colorScheme.onSurface;
    }

    return Text(
      line,
      style: TextStyle(
        color: color,
        fontFamily: 'monospace',
        fontSize: 12,
        height: 1.4,
      ),
      softWrap: false,
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
            Icon(Icons.error_outline, color: theme.colorScheme.error, size: 40),
            const SizedBox(height: 16),
            Text(
              error,
              textAlign: TextAlign.center,
              style: TextStyle(color: theme.colorScheme.error),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 16),
              FilledButton(
                onPressed: onRetry,
                child: Text(l10n(context).retry),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
