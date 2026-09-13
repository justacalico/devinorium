part of '../settings_page.dart';

class _WorktreeRootSection extends StatefulWidget {
  final AppState state;

  const _WorktreeRootSection({required this.state});

  @override
  State<_WorktreeRootSection> createState() => _WorktreeRootSectionState();
}

class _WorktreeRootSectionState extends State<_WorktreeRootSection> {
  final _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    _controller.text = widget.state.worktreeRoot ?? '';
    _controller.addListener(_onTextChanged);
  }

  void _onTextChanged() {
    setState(() {});
  }

  @override
  void didUpdateWidget(covariant _WorktreeRootSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    final root = widget.state.worktreeRoot ?? '';
    if (_controller.text.isEmpty && root.isNotEmpty) {
      _controller.text = root;
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final text = _controller.text.trim();
    await widget.state.setWorktreeRoot(text.isEmpty ? null : text);
    if (mounted && widget.state.globalError.isEmpty) {
      _controller.text = widget.state.worktreeRoot ?? '';
    }
  }

  Future<void> _browse() async {
    final picked = await showFolderPickerDialog(
      context,
      api: widget.state.api,
      initialPath: _controller.text,
      title: l10n(context).worktreeRoot,
    );
    if (picked != null && mounted) {
      _controller.text = picked;
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = l10n(context);
    final isOwner = widget.state.isOwner;
    final current = widget.state.worktreeRoot;
    final loading = widget.state.loadingWorktreeRoot;

    return _SectionCard(
      title: l.worktreeRoot,
      children: [
        Text(
          l.worktreeRootDescription,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 16),
        if (!isOwner)
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                current ?? l.worktreeRootNotSet,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                l.worktreeRootOnlyOwner,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          )
        else
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  enabled: !loading,
                  decoration: InputDecoration(
                    hintText: '/absolute/path/to/worktrees',
                    isDense: true,
                    border: const OutlineInputBorder(),
                    suffixIcon: _controller.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear, size: 18),
                            tooltip: l.clear,
                            onPressed: loading
                                ? null
                                : () {
                                    _controller.clear();
                                    _save();
                                  },
                          )
                        : null,
                  ),
                  onSubmitted: (_) => _save(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.folder_open_outlined),
                tooltip: l.worktreeRootBrowse,
                onPressed: loading ? null : _browse,
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: loading ? null : _save,
                child: loading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(l.worktreeRootSave),
              ),
            ],
          ),
        if (widget.state.globalError.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            widget.state.globalError,
            style: TextStyle(color: theme.colorScheme.error),
          ),
        ],
      ],
    );
  }
}
