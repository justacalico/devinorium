import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../utils/git_status.dart';
import 'file_viewer.dart';

typedef _GitPanelModel = ({
  int? projectId,
  String? activeThreadId,
  AppMode appMode,
  GitChanges? changes,
  GitRepoInfo? repoInfo,
  bool loading,
  bool busy,
  bool unsupported,
  String error,
  String? scopeKey,
  String? loadedScopeKey,
});

/// The sidebar Git panel: working-tree changes, staging, commit, pull, push.
///
/// Scoped like the files panel — a worktree scope shows the worktree's own
/// changes and runs operations inside it via the thread's thread_id.
class GitPanel extends StatefulWidget {
  const GitPanel({super.key});

  @override
  State<GitPanel> createState() => _GitPanelState();
}

class _GitPanelState extends State<GitPanel> {
  final TextEditingController _commitController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _commitController.addListener(() => setState(() {}));
    _loadIfNeeded(context.read<AppState>());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _loadIfNeeded(context.read<AppState>());
  }

  @override
  void dispose() {
    _commitController.dispose();
    super.dispose();
  }

  void _loadIfNeeded(AppState state) {
    if (state.gitPanelScopeKey == state.activeFilesScopeKey) return;
    if (state.appMode == AppMode.editor && state.activeThreadId == null) {
      return;
    }
    unawaited(state.reloadGitChanges());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = l10n(context);
    final state = context.read<AppState>();

    return Selector<AppState, _GitPanelModel>(
      selector: (_, s) => (
        projectId: s.activeProjectId,
        activeThreadId: s.activeThreadId,
        appMode: s.appMode,
        changes: s.gitPanelChanges,
        repoInfo: s.gitPanelRepoInfo,
        loading: s.gitPanelLoading,
        busy: s.gitActionBusy,
        unsupported: s.gitPanelUnsupported,
        error: s.gitPanelError,
        scopeKey: s.activeFilesScopeKey,
        loadedScopeKey: s.gitPanelScopeKey,
      ),
      builder: (context, model, _) {
        final showPanel =
            model.projectId != null &&
            (model.appMode != AppMode.editor || model.activeThreadId != null);
        if (showPanel && model.scopeKey != model.loadedScopeKey) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            // A message typed for one repo must not commit into another.
            _commitController.clear();
            unawaited(state.reloadGitChanges());
          });
        }
        final scopeKey = model.scopeKey;
        final worktreeScope =
            scopeKey != null && scopeKey.startsWith('worktree:')
            ? scopeKey.substring('worktree:'.length)
            : null;

        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      l.git.toUpperCase(),
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  if (worktreeScope != null)
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: Tooltip(
                        message: worktreeScope,
                        child: Icon(
                          Icons.folder_copy_outlined,
                          size: 14,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  if (showPanel)
                    if (model.loading && !model.busy)
                      const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else
                      IconButton(
                        tooltip: l.refresh,
                        icon: const Icon(Icons.refresh, size: 18),
                        onPressed: model.busy
                            ? null
                            : () => state.reloadGitChanges(),
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.all(4),
                      ),
                ],
              ),
            ),
            const Divider(height: 1),
            if (model.error.isNotEmpty && model.changes != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
                child: Text(
                  model.error,
                  style: TextStyle(
                    color: theme.colorScheme.error,
                    fontSize: 12,
                  ),
                ),
              ),
            Expanded(child: _buildBody(context, state, model)),
          ],
        );
      },
    );
  }

  Widget _buildBody(
    BuildContext context,
    AppState state,
    _GitPanelModel model,
  ) {
    final theme = Theme.of(context);
    final l = l10n(context);

    if (model.projectId == null) {
      return _Placeholder(text: l.selectProjectFirst);
    }
    if (model.appMode == AppMode.editor && model.activeThreadId == null) {
      return _Placeholder(text: l.selectOrCreateThread);
    }
    if (model.unsupported) {
      return _Placeholder(text: l.gitUnsupportedBackend);
    }
    if (model.changes == null) {
      if (model.loading) {
        return const Padding(
          padding: EdgeInsets.all(16),
          child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
        );
      }
      if (model.error.isNotEmpty) {
        return Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            model.error,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        );
      }
      return _Placeholder(text: l.notGitRepo);
    }

    final changes = model.changes!;
    final staged = changes.staged;
    final unstaged = changes.unstaged;
    final busy = model.busy;

    return ListView(
      padding: const EdgeInsets.only(bottom: 16),
      children: [
        _branchHeader(context, state, changes, model, l, theme),
        _commitBox(context, state, changes, l, theme, busy),
        if (staged.isNotEmpty) ...[
          _sectionHeader(
            l.stagedChanges,
            staged.length,
            theme,
            actionLabel: l.unstageAll,
            onAction: busy ? null : () => state.gitUnstageAll(),
          ),
          for (final e in staged)
            _changeRow(context, state, e, staged: true, busy: busy),
        ],
        if (unstaged.isNotEmpty) ...[
          _sectionHeader(
            l.changes,
            unstaged.length,
            theme,
            actionLabel: l.stageAll,
            onAction: busy ? null : () => state.gitStageAll(),
          ),
          for (final e in unstaged)
            _changeRow(context, state, e, staged: false, busy: busy),
        ],
        if (changes.isClean)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              l.noChanges,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }

  Widget _branchHeader(
    BuildContext context,
    AppState state,
    GitChanges changes,
    _GitPanelModel model,
    AppLocalizations l,
    ThemeData theme,
  ) {
    final busy = model.busy;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 8, 4),
      child: Row(
        children: [
          Icon(
            Icons.account_tree_outlined,
            size: 15,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              changes.branch.isEmpty ? 'HEAD' : changes.branch,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (changes.behind > 0)
            Padding(
              padding: const EdgeInsets.only(right: 2),
              child: Text(
                '↓${changes.behind}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          if (changes.ahead > 0)
            Padding(
              padding: const EdgeInsets.only(right: 2),
              child: Text(
                '↑${changes.ahead}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          IconButton(
            tooltip: l.pull,
            icon: const Icon(Icons.download_outlined, size: 18),
            onPressed: busy ? null : () => state.gitPanelPull(),
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.all(4),
          ),
          IconButton(
            tooltip: l.push,
            icon: const Icon(Icons.upload_outlined, size: 18),
            onPressed: busy ? null : () => state.gitPanelPush(),
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.all(4),
          ),
        ],
      ),
    );
  }

  Widget _commitBox(
    BuildContext context,
    AppState state,
    GitChanges changes,
    AppLocalizations l,
    ThemeData theme,
    bool busy,
  ) {
    final canCommit =
        _commitController.text.trim().isNotEmpty &&
        !changes.isClean &&
        !busy;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 8),
      child: Column(
        children: [
          TextField(
            controller: _commitController,
            decoration: InputDecoration(
              hintText: l.commitMessageHint,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 8,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            style: theme.textTheme.bodySmall,
            minLines: 1,
            maxLines: 3,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) {
              if (canCommit) _commit(context, state, changes);
            },
          ),
          const SizedBox(height: 6),
          SizedBox(
            width: double.infinity,
            child: FilledButton.tonal(
              onPressed: canCommit
                  ? () => _commit(context, state, changes)
                  : null,
              child: busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(l.commit),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _commit(
    BuildContext context,
    AppState state,
    GitChanges changes,
  ) async {
    final l = l10n(context);
    // Nothing staged but worktree dirty: this is the "commit all" flow and
    // stages unstaged files too, so confirm first like VS Code does.
    if (changes.staged.isEmpty && changes.unstaged.isNotEmpty) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          content: Text(l.gitCommitAllConfirm),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(l.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(l.commit),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    final ok = await state.gitCommitChanges(_commitController.text);
    if (ok && mounted) {
      _commitController.clear();
    }
  }

  Widget _sectionHeader(
    String title,
    int count,
    ThemeData theme, {
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 8, 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '$title ($count)'.toUpperCase(),
              style: theme.textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          if (actionLabel != null)
            InkWell(
              onTap: onAction,
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 2,
                ),
                child: Text(
                  actionLabel,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: onAction == null
                        ? theme.colorScheme.onSurfaceVariant
                        : theme.colorScheme.primary,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _changeRow(
    BuildContext context,
    AppState state,
    GitChangeEntry entry, {
    required bool staged,
    required bool busy,
  }) {
    final theme = Theme.of(context);
    final color = gitStatusColor(entry.status, theme);
    // Git paths are always posix-separated, even on Windows.
    final posix = p.Context(style: p.Style.posix);
    final name = posix.basename(entry.path);
    final dir = posix.dirname(entry.path);
    final openable = entry.status != 'deleted';

    return InkWell(
      onTap: openable ? () => _openChange(context, state, entry) : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 3, 8, 3),
        child: Row(
          children: [
            SizedBox(
              width: 16,
              child: Text(
                gitStatusLetter(entry.status),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: name),
                    if (dir != '.')
                      TextSpan(
                        text: '  $dir',
                        style: TextStyle(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ),
            IconButton(
              tooltip: staged ? l10n(context).unstage : l10n(context).stage,
              icon: Icon(
                staged ? Icons.remove_outlined : Icons.add,
                size: 16,
              ),
              onPressed: busy
                  ? null
                  : () => staged
                      ? state.gitUnstagePaths([entry.path])
                      : state.gitStagePaths([entry.path]),
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.all(4),
            ),
          ],
        ),
      ),
    );
  }

  void _openChange(BuildContext context, AppState state, GitChangeEntry entry) {
    final toplevel = state.gitPanelRepoInfo?.toplevel;
    if (toplevel == null || toplevel.isEmpty) return;
    final path = p.join(toplevel, entry.path);
    if (state.appMode == AppMode.editor) {
      unawaited(state.openEditorFile(path));
      final scaffold = Scaffold.maybeOf(context);
      if (scaffold?.isDrawerOpen ?? false) {
        scaffold!.closeDrawer();
      }
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => FileViewerPage(
          path: path,
          projectId: state.activeProjectId,
          threadId: state.gitApiThreadId,
          gitStatus: entry.status,
        ),
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  final String text;

  const _Placeholder({required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Text(
        text,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
