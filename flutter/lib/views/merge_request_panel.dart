import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import '../merge_request/github_merge_request_provider.dart';
import '../merge_request/gitlab_merge_request_provider.dart';
import '../merge_request/merge_request_models.dart';
import '../merge_request/merge_request_provider.dart';
import '../state/app_state.dart';
import '../utils/link_opener.dart';
import 'job_log_dialog.dart';
import 'merge_request_view.dart';

/// A modal panel that loads and displays a merge request.
///
/// The actual content lives in [MergeRequestView]; this widget only owns the
/// provider and the dialog chrome so the view can be reused elsewhere.
class MergeRequestPanel extends StatefulWidget {
  final String url;
  final MergeRequestProvider? provider;

  const MergeRequestPanel({super.key, required this.url, this.provider});

  @override
  State<MergeRequestPanel> createState() => _MergeRequestPanelState();
}

class _MergeRequestPanelState extends State<MergeRequestPanel> {
  MergeRequestProvider? _provider;
  bool _ownsProvider = false;
  ModalRoute<dynamic>? _jobLogRoute;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _provider ??= _createProvider();
  }

  @override
  void didUpdateWidget(covariant MergeRequestPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The panel can be reused with a different URL or provider while
    // mounted; drop the old state and reload instead of showing stale data.
    if (oldWidget.url != widget.url || oldWidget.provider != widget.provider) {
      // An open job log polls the outgoing provider; close it before the
      // swap.
      final jobLogRoute = _jobLogRoute;
      _jobLogRoute = null;
      if (jobLogRoute != null) {
        scheduleMicrotask(() {
          jobLogRoute.navigator?.removeRoute(jobLogRoute);
        });
      }
      if (_ownsProvider) _provider?.dispose();
      _ownsProvider = false;
      _provider = null;
      _provider = _createProvider();
    }
  }

  MergeRequestProvider _createProvider() {
    if (widget.provider != null) {
      return widget.provider!;
    }
    _ownsProvider = true;
    final client = context.read<AppState>().api.client;
    if (GitHubMergeRequestProvider.canHandleUrl(widget.url)) {
      return GitHubMergeRequestProvider(client)..load(widget.url);
    }
    return GitLabMergeRequestProvider(client)..load(widget.url);
  }

  @override
  void dispose() {
    // The job-log dialog polls this panel's provider; close it before the
    // provider is torn down or the poll outlives its data source. The
    // removal is deferred because the navigator can be locked while the
    // tree is unmounting.
    final jobLogRoute = _jobLogRoute;
    _jobLogRoute = null;
    if (jobLogRoute != null) {
      scheduleMicrotask(() {
        jobLogRoute.navigator?.removeRoute(jobLogRoute);
      });
    }
    if (_ownsProvider) _provider?.dispose();
    super.dispose();
  }

  void _showJobLog(BuildContext context, MergeRequestPipelineJob job) {
    final provider = _provider;
    if (provider == null || !provider.supportsPipelines) return;

    final appState = context.read<AppState>();
    // Push directly so the route handle exists before the widget can be
    // disposed; showDialog only exposes it inside the builder.
    final route = DialogRoute<void>(
      context: context,
      builder: (dialogContext) => JobLogDialog(
        job: job,
        onLoad: () => provider.loadJobLog(job),
        onOpenInBrowser: job.webUrl.isNotEmpty && isOpenableLink(job.webUrl)
            ? () => appState.openLink(job.webUrl)
            : null,
      ),
    );
    _jobLogRoute = route;
    unawaited(
      Navigator.of(context, rootNavigator: true).push(route).then((_) {
        if (identical(_jobLogRoute, route)) _jobLogRoute = null;
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = context.read<AppState>();
    final media = MediaQuery.of(context);

    return Stack(
      children: [
        ModalBarrier(
          color: theme.colorScheme.scrim.withValues(alpha: 0.5),
          dismissible: false,
        ),
        Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 960,
              maxHeight: media.size.height * 0.92,
            ),
            child: Card(
              margin: const EdgeInsets.all(24),
              elevation: 3,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 12, 0),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            l10n(context).mergeRequest,
                            style: theme.textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: l10n(context).close,
                          icon: const Icon(Icons.close),
                          onPressed: state.closeDialog,
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                      child: ListenableBuilder(
                        listenable: _provider!,
                        builder: (context, _) => MergeRequestView(
                          detail: _provider!.value,
                          url: widget.url,
                          onRetry: () => _provider!.load(widget.url),
                          onLinkTap: (url) =>
                              context.read<AppState>().openLink(url),
                          onLoadJobs: _provider!.supportsPipelines
                              ? _provider!.loadJobs
                              : null,
                          onJobTap: _provider!.supportsPipelines
                              ? (job) => _showJobLog(context, job)
                              : null,
                          onLoadFile: _provider!.supportsFiles
                              ? _provider!.loadFile
                              : null,
                          onAction: _provider!.perform,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
