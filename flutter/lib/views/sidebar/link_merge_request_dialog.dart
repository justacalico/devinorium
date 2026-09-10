import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../models/git.dart';

/// Lets the user paste a GitLab merge request URL to attach to a thread.
/// Returns the parsed URL through [Navigator.pop] when saved.
class LinkMergeRequestDialog extends StatefulWidget {
  const LinkMergeRequestDialog({super.key});

  @override
  State<LinkMergeRequestDialog> createState() => _LinkMergeRequestDialogState();
}

class _LinkMergeRequestDialogState extends State<LinkMergeRequestDialog> {
  late final TextEditingController _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final url = _controller.text.trim();
    if (url.isEmpty) {
      Navigator.of(context).pop(null);
      return;
    }
    final ref = LinkedMergeRequestRef.tryParse(url);
    if (ref == null) {
      setState(() => _error = l10n(context).invalidMergeRequestUrl);
      return;
    }
    Navigator.of(context).pop(ref.webUrl);
  }

  @override
  Widget build(BuildContext context) {
    final l = l10n(context);

    return AlertDialog(
      title: Text(l.linkMergeRequest),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: TextField(
          controller: _controller,
          autofocus: true,
          decoration: InputDecoration(
            hintText: l.mergeRequestUrlHint,
            errorText: _error,
          ),
          keyboardType: TextInputType.url,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _submit(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l.cancel),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(l.save),
        ),
      ],
    );
  }
}
