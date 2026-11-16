part of '../settings_page.dart';

class _DirectoriesSection extends StatelessWidget {
  final AppState state;

  const _DirectoriesSection({required this.state});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = l10n(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _RootPathCard(
          state: state,
          title: l.cloneRoot,
          description: l.cloneRootDescription,
          notSetLabel: l.cloneRootNotSet,
          ownerOnlyLabel: l.cloneRootOnlyOwner,
          browseTooltip: l.cloneRootBrowse,
          saveLabel: l.cloneRootSave,
          hintText: '/absolute/path/to/clones',
          pickerTitle: l.cloneRoot,
          getValue: () => state.cloneRoot,
          getLoading: () => state.loadingCloneRoot,
          onSave: state.setCloneRoot,
        ),
        _RootPathCard(
          state: state,
          title: l.worktreeRoot,
          description: l.worktreeRootDescription,
          notSetLabel: l.worktreeRootNotSet,
          ownerOnlyLabel: l.worktreeRootOnlyOwner,
          browseTooltip: l.worktreeRootBrowse,
          saveLabel: l.worktreeRootSave,
          hintText: '/absolute/path/to/worktrees',
          pickerTitle: l.worktreeRoot,
          getValue: () => state.worktreeRoot,
          getLoading: () => state.loadingWorktreeRoot,
          onSave: state.setWorktreeRoot,
        ),
        _RootPathCard(
          state: state,
          title: l.projectRoot,
          description: l.projectRootDescription,
          notSetLabel: l.projectRootNotSet,
          ownerOnlyLabel: l.projectRootOnlyOwner,
          browseTooltip: l.projectRootBrowse,
          saveLabel: l.projectRootSave,
          hintText: '/absolute/path/to/projects',
          pickerTitle: l.projectRoot,
          getValue: () => state.projectRoot,
          getLoading: () => state.loadingProjectRoot,
          onSave: state.setProjectRoot,
        ),
        // Shown once for all cards; each save reports through the shared
        // globalError field.
        Selector<AppState, String>(
          selector: (_, s) => s.globalError,
          builder: (context, error, _) {
            if (error.isEmpty) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(
                error,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            );
          },
        ),
      ],
    );
  }
}

class _RootPathCard extends StatefulWidget {
  final AppState state;
  final String title;
  final String description;
  final String notSetLabel;
  final String ownerOnlyLabel;
  final String browseTooltip;
  final String saveLabel;
  final String hintText;
  final String pickerTitle;
  final String? Function() getValue;
  final bool Function() getLoading;
  final Future<void> Function(String? path) onSave;

  const _RootPathCard({
    required this.state,
    required this.title,
    required this.description,
    required this.notSetLabel,
    required this.ownerOnlyLabel,
    required this.browseTooltip,
    required this.saveLabel,
    required this.hintText,
    required this.pickerTitle,
    required this.getValue,
    required this.getLoading,
    required this.onSave,
  });

  @override
  State<_RootPathCard> createState() => _RootPathCardState();
}

class _RootPathCardState extends State<_RootPathCard> {
  final _controller = TextEditingController();
  String? _seenServerId;
  String? _seenValue;
  bool _seenLoading = false;

  @override
  void initState() {
    super.initState();
    _seenServerId = widget.state.activeServerId;
    _seenValue = widget.getValue();
    _seenLoading = widget.getLoading();
    _controller.text = _seenValue ?? '';
    _controller.addListener(_onTextChanged);
    widget.state.addListener(_onValueChanged);
  }

  void _onTextChanged() {
    setState(() {});
  }

  // A server switch replaces the scoped root, and the new server's value
  // arrives one or more notifications later. On a switch the stored value
  // still belongs to the old server, so the field clears until the new
  // server's root loads in; remembering it keeps a stale notify from
  // filling the field back with the old path. On the same server,
  // getValue() only changes via loads and saves, never from typing.
  void _onValueChanged() {
    final serverId = widget.state.activeServerId;
    final value = widget.getValue();
    final loading = widget.getLoading();
    if (serverId != _seenServerId) {
      _seenServerId = serverId;
      _seenValue = value;
      _seenLoading = loading;
      _controller.text = '';
      setState(() {});
      return;
    }
    if (value == _seenValue) {
      if (loading != _seenLoading) {
        _seenLoading = loading;
        setState(() {});
      }
      return;
    }
    _seenValue = value;
    _seenLoading = loading;
    _controller.text = value ?? '';
    setState(() {});
  }

  @override
  void didUpdateWidget(covariant _RootPathCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      oldWidget.state.removeListener(_onValueChanged);
      widget.state.addListener(_onValueChanged);
      _seenServerId = widget.state.activeServerId;
      _seenValue = widget.getValue();
      _seenLoading = widget.getLoading();
      _controller.text = _seenValue ?? '';
      return;
    }
    final root = widget.getValue() ?? '';
    if (_controller.text.isEmpty && root.isNotEmpty) {
      _controller.text = root;
      _seenValue = root;
    }
  }

  @override
  void dispose() {
    widget.state.removeListener(_onValueChanged);
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final text = _controller.text.trim();
    await widget.onSave(text.isEmpty ? null : text);
  }

  Future<void> _browse() async {
    final picked = await showFolderPickerDialog(
      context,
      api: widget.state.api,
      initialPath: _controller.text,
      title: widget.pickerTitle,
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
    final current = widget.getValue();
    final loading = widget.getLoading();

    return _SectionCard(
      title: widget.title,
      children: [
        Text(
          widget.description,
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
                current ?? widget.notSetLabel,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                widget.ownerOnlyLabel,
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
                    hintText: widget.hintText,
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
                tooltip: widget.browseTooltip,
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
                    : Text(widget.saveLabel),
              ),
            ],
          ),
      ],
    );
  }
}
