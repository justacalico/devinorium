import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
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

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _provider ??= _createProvider();
  }

  MergeRequestProvider _createProvider() {
    if (widget.provider != null) {
      return widget.provider!;
    }
    _ownsProvider = true;
    final client = context.read<AppState>().api.client;
    return GitLabMergeRequestProvider(client)..load(widget.url);
  }

  @override
  void dispose() {
    if (_ownsProvider) _provider?.dispose();
    super.dispose();
  }

  void _showJobLog(BuildContext context, MergeRequestPipelineJob job) {
    final provider = _provider;
    if (provider is! GitLabMergeRequestProvider) return;

    final appState = context.read<AppState>();
    showDialog(
      context: context,
      builder: (context) => JobLogDialog(
        job: job,
        onLoad: () => provider.loadJobLog(job),
        onOpenInBrowser: job.webUrl.isNotEmpty && isOpenableLink(job.webUrl)
            ? () => appState.openLink(job.webUrl)
            : null,
      ),
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
                          onLoadJobs: _provider! is GitLabMergeRequestProvider
                              ? _provider!.loadJobs
                              : null,
                          onJobTap: _provider! is GitLabMergeRequestProvider
                              ? (job) => _showJobLog(context, job)
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
