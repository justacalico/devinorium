import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../issue/gitlab_issue_provider.dart';
import '../issue/issue_provider.dart';
import '../l10n/l10n.dart';
import '../state/app_state.dart';
import 'issue_view.dart';

/// A modal panel that loads and displays a GitLab issue.
///
/// The actual content lives in [IssueView]; this widget only owns the
/// provider and the dialog chrome so the view can be reused elsewhere.
class IssuePanel extends StatefulWidget {
  final String url;
  final IssueProvider? provider;

  const IssuePanel({super.key, required this.url, this.provider});

  @override
  State<IssuePanel> createState() => _IssuePanelState();
}

class _IssuePanelState extends State<IssuePanel> {
  late final IssueProvider _provider;

  @override
  void initState() {
    super.initState();
    _provider =
        widget.provider ?? GitLabIssueProvider(context.read<AppState>().api.client);
    _provider.load(widget.url);
  }

  @override
  void dispose() {
    _provider.dispose();
    super.dispose();
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
                            l10n(context).issue,
                            style: theme.textTheme.titleLarge
                                ?.copyWith(fontWeight: FontWeight.w600),
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
                        listenable: _provider,
                        builder: (context, _) => IssueView(
                          detail: _provider.value,
                          url: widget.url,
                          onRetry: () => _provider.load(widget.url),
                          onLinkTap: (url) =>
                              context.read<AppState>().openLink(url),
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
