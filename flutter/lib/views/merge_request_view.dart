import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart'
    hide SyntaxHighlighter;
import 'package:markdown/markdown.dart' as markdown;

import '../l10n/l10n.dart';
import '../merge_request/diff_stats.dart';
import '../merge_request/merge_request_models.dart';
import '../state/async_value.dart';
import '../theme/semantic_colors.dart';
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

  /// Loads the raw bytes of a changed file at a git ref. When null, binary
  /// image diffs fall back to the text diff placeholder.
  final MergeRequestFileLoader? onLoadFile;

  const MergeRequestView({
    super.key,
    required this.detail,
    this.url,
    this.onRetry,
    this.onLinkTap,
    this.onLoadJobs,
    this.onJobTap,
    this.onAction,
    this.onLoadFile,
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
        onLoadFile: onLoadFile,
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
  final MergeRequestFileLoader? onLoadFile;

  const _MergeRequestBody({
    required this.detail,
    this.url,
    this.onLinkTap,
    this.onLoadJobs,
    this.onJobTap,
    this.onAction,
    this.onLoadFile,
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
              _ChangesTab(
                changes: detail.changes,
                onLoadFile: widget.onLoadFile,
                // The diff refs pin the exact commits the diff was computed
                // against; fall back to the branch names when they are
                // absent (older GitLab versions, partial responses).
                oldRef: detail.diffBaseSha.isNotEmpty
                    ? detail.diffBaseSha
                    : detail.targetBranch,
                newRef: detail.diffHeadSha.isNotEmpty
                    ? detail.diffHeadSha
                    : detail.sourceBranch,
              ),
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
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    flex: 3,
                    child: Text(
                      detail.branches,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.primary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (author != null) ...[
                    const SizedBox(width: 12),
                    Flexible(
                      child: Text(
                        '@${author.username}',
                        style: theme.textTheme.labelMedium,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ],
              ),
            ),
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
  final semantic = SemanticColors.of(context);
  final color = switch (detail.state) {
    'opened' || 'open' => theme.colorScheme.primary,
    'merged' => semantic.success,
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
  final semantic =
      theme.extension<SemanticColors>() ??
      SemanticColors.fallback(theme.brightness);
  final lower = status.toLowerCase();
  if (lower == 'success') return semantic.success;
  if (lower == 'failed' || lower == 'failure') return theme.colorScheme.error;
  if (lower == 'running') return theme.colorScheme.primary;
  if (lower == 'pending' ||
      lower == 'created' ||
      lower == 'waiting_for_resource') {
    return semantic.warning;
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

  /// Loads file bytes at a git ref for inline image diffs. When null, binary
  /// image files keep the text diff placeholder.
  final MergeRequestFileLoader? onLoadFile;

  /// Git ref the "old" side of the diff is based on.
  final String oldRef;

  /// Git ref the "new" side of the diff was generated from.
  final String newRef;

  const _ChangesTab({
    required this.changes,
    this.onLoadFile,
    this.oldRef = '',
    this.newRef = '',
  });

  @override
  State<_ChangesTab> createState() => _ChangesTabState();
}

class _ChangesTabState extends State<_ChangesTab> {
  int? _expanded;
  late List<DiffStats> _changeStats;

  @override
  void initState() {
    super.initState();
    _changeStats = _computeStats();
  }

  @override
  void didUpdateWidget(covariant _ChangesTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_sameChanges(oldWidget.changes, widget.changes)) {
      _changeStats = _computeStats();
    }
  }

  bool _sameChanges(List<MergeRequestChange> a, List<MergeRequestChange> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!identical(a[i], b[i])) return false;
    }
    return true;
  }

  List<DiffStats> _computeStats() => [
    for (final change in widget.changes) DiffStats.parse(change.diff),
  ];

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

    final total = DiffStats.total(_changeStats);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(
            children: [
              Text(
                l10n(context).changesFileCount(widget.changes.length),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              if (!total.isZero) ...[
                const SizedBox(width: 8),
                _DiffStatsText(stats: total),
              ],
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.only(top: 8, bottom: 24),
            itemCount: widget.changes.length,
            itemBuilder: (context, index) {
              final change = widget.changes[index];
              final isExpanded = _expanded == index;
              return Card(
                margin: const EdgeInsets.symmetric(vertical: 4),
                child: InkWell(
                  onTap: () =>
                      setState(() => _expanded = isExpanded ? null : index),
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            _changeIcon(change, context),
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
                            if (!_changeStats[index].isZero) ...[
                              const SizedBox(width: 8),
                              _DiffStatsText(stats: _changeStats[index]),
                              const SizedBox(width: 8),
                            ],
                            Icon(
                              isExpanded
                                  ? Icons.expand_less
                                  : Icons.expand_more,
                              size: 18,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ],
                        ),
                        if (isExpanded &&
                            (change.diff.isNotEmpty ||
                                (change.isBinaryImage &&
                                    widget.onLoadFile != null))) ...[
                          const SizedBox(height: 8),
                          if (change.isBinaryImage && widget.onLoadFile != null)
                            _ImageDiffView(
                              change: change,
                              oldRef: widget.oldRef,
                              newRef: widget.newRef,
                              loadFile: widget.onLoadFile!,
                            )
                          else
                            _DiffView(diff: change.diff),
                        ],
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _changeIcon(MergeRequestChange change, BuildContext context) {
    final theme = Theme.of(context);
    final semantic = SemanticColors.of(context);
    if (change.newFile) {
      return Icon(Icons.add, size: 18, color: semantic.success);
    }
    if (change.deletedFile) {
      return Icon(Icons.remove, size: 18, color: theme.colorScheme.error);
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

class _DiffStatsText extends StatelessWidget {
  final DiffStats stats;

  const _DiffStatsText({required this.stats});

  @override
  Widget build(BuildContext context) {
    if (stats.isZero) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final semantic = SemanticColors.of(context);
    final base = theme.textTheme.labelMedium;
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: '+${stats.additions}',
            style: base?.copyWith(color: semantic.success),
          ),
          TextSpan(text: ' ', style: base),
          TextSpan(
            text: '-${stats.deletions}',
            style: base?.copyWith(color: theme.colorScheme.error),
          ),
        ],
      ),
    );
  }
}

/// Renders a binary image change by loading both sides of the diff and
/// showing the pictures inline. Falls back to the raw diff text when the
/// bytes cannot be fetched or decoded.
class _ImageDiffView extends StatefulWidget {
  final MergeRequestChange change;
  final String oldRef;
  final String newRef;
  final MergeRequestFileLoader loadFile;

  const _ImageDiffView({
    required this.change,
    required this.oldRef,
    required this.newRef,
    required this.loadFile,
  });

  @override
  State<_ImageDiffView> createState() => _ImageDiffViewState();
}

class _ImageDiffViewState extends State<_ImageDiffView> {
  /// (old bytes, new bytes); a null entry means that side does not exist or
  /// could not be loaded.
  late Future<(Uint8List?, Uint8List?)> _images;

  @override
  void initState() {
    super.initState();
    _images = _load();
  }

  @override
  void didUpdateWidget(covariant _ImageDiffView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // MergeRequestChange has no equality; compare the fields that select
    // which blobs get loaded so a refresh with identical changes does not
    // refetch the images.
    final old = oldWidget.change;
    final change = widget.change;
    if (old.oldPath != change.oldPath ||
        old.newPath != change.newPath ||
        old.newFile != change.newFile ||
        old.deletedFile != change.deletedFile ||
        oldWidget.oldRef != widget.oldRef ||
        oldWidget.newRef != widget.newRef ||
        oldWidget.loadFile != widget.loadFile) {
      _images = _load();
    }
  }

  Future<(Uint8List?, Uint8List?)> _load() {
    final change = widget.change;
    return Future.wait([
      if (change.newFile)
        Future<Uint8List?>.value()
      else
        widget.loadFile(change.oldPath, widget.oldRef),
      if (change.deletedFile)
        Future<Uint8List?>.value()
      else
        widget.loadFile(change.newPath, widget.newRef),
    ]).then((r) => (r[0], r[1]));
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<(Uint8List?, Uint8List?)>(
      future: _images,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }

        final oldBytes = snapshot.data?.$1;
        final newBytes = snapshot.data?.$2;
        if (oldBytes == null && newBytes == null) {
          return _DiffView(diff: widget.change.diff);
        }

        final showLabels = oldBytes != null && newBytes != null;
        return Wrap(
          spacing: 16,
          runSpacing: 12,
          children: [
            if (oldBytes != null)
              _ImageSide(
                label: showLabels ? l10n(context).diffImageBefore : null,
                bytes: oldBytes,
              ),
            if (newBytes != null)
              _ImageSide(
                label: showLabels ? l10n(context).diffImageAfter : null,
                bytes: newBytes,
              ),
          ],
        );
      },
    );
  }
}

class _ImageSide extends StatelessWidget {
  final String? label;
  final Uint8List bytes;

  const _ImageSide({this.label, required this.bytes});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final unavailable = Padding(
      padding: const EdgeInsets.all(16),
      child: Text(
        l10n(context).diffImageUnavailable,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (label != null) ...[
          Text(
            label!,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
        ],
        Container(
          constraints: const BoxConstraints(maxWidth: 440, maxHeight: 440),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHigh,
            border: Border.all(color: theme.colorScheme.outlineVariant),
            borderRadius: BorderRadius.circular(8),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(7),
            child: Image.memory(
              bytes,
              fit: BoxFit.contain,
              errorBuilder: (context, error, stackTrace) => unavailable,
            ),
          ),
        ),
      ],
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
    final semantic =
        theme.extension<SemanticColors>() ??
        SemanticColors.fallback(theme.brightness);
    Color color;
    if (line.startsWith('@@') ||
        line.startsWith('---') ||
        line.startsWith('+++') ||
        line.startsWith('diff ') ||
        line.startsWith('index ')) {
      color = theme.colorScheme.primary;
    } else if (line.startsWith('+')) {
      color = semantic.success;
    } else if (line.startsWith('-')) {
      color = theme.colorScheme.error;
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
