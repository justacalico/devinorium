import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/l10n.dart';
import '../utils/debug_log.dart';
import '../utils/link_opener.dart' as link_opener;

/// Wraps the app root and shows a one-time startup dialog for builds produced
/// from a merge request. The ID and URL are baked in via `--dart-define`, so
/// the prompt survives merging and remains as proof of the build's source.
class DevMergeRequestWrapper extends StatefulWidget {
  final Widget child;
  final String mergeRequestId;
  final String mergeRequestUrl;

  const DevMergeRequestWrapper({
    super.key,
    required this.child,
    this.mergeRequestId = const String.fromEnvironment('MERGE_REQUEST_ID'),
    this.mergeRequestUrl = const String.fromEnvironment('MERGE_REQUEST_URL'),
  });

  @override
  State<DevMergeRequestWrapper> createState() => _DevMergeRequestWrapperState();
}

class _DevMergeRequestWrapperState extends State<DevMergeRequestWrapper> {
  @override
  void initState() {
    super.initState();
    if (widget.mergeRequestId.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _showDialog());
    }
  }

  void _showDialog() {
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => DevMergeRequestDialog(
        mergeRequestId: widget.mergeRequestId,
        mergeRequestUrl: widget.mergeRequestUrl,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class DevMergeRequestDialog extends StatelessWidget {
  final String mergeRequestId;
  final String mergeRequestUrl;

  const DevMergeRequestDialog({
    super.key,
    required this.mergeRequestId,
    required this.mergeRequestUrl,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasUrl = link_opener.isOpenableLink(mergeRequestUrl);

    return AlertDialog(
      title: Text(l10n(context).devMergeRequestTitle),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              hasUrl
                  ? l10n(context).devMergeRequestBody(mergeRequestId, mergeRequestUrl)
                  : l10n(context).devMergeRequestBodyNoUrl(mergeRequestId),
              style: theme.textTheme.bodyMedium,
            ),
            if (hasUrl) ...[
              const SizedBox(height: 16),
              SelectableText(
                mergeRequestUrl,
                style: const TextStyle(fontFamily: 'monospace'),
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (hasUrl)
          TextButton(
            onPressed: () => unawaited(
              Clipboard.setData(ClipboardData(text: mergeRequestUrl))
                  .catchError((e) => debugLogFailure('devMergeRequest.copy', e)),
            ),
            child: Text(l10n(context).devMergeRequestCopy),
          ),
        if (hasUrl)
          TextButton(
            onPressed: () => unawaited(
              link_opener
                  .openLink(mergeRequestUrl)
                  .catchError((e) => debugLogFailure('devMergeRequest.openLink', e)),
            ),
            child: Text(l10n(context).devMergeRequestOpen),
          ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n(context).devMergeRequestClose),
        ),
      ],
    );
  }
}
