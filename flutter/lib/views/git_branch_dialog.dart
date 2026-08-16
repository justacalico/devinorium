import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import '../models/models.dart';
import '../state/app_state.dart';

class GitBranchDialog extends StatefulWidget {
  const GitBranchDialog({super.key});

  @override
  State<GitBranchDialog> createState() => _GitBranchDialogState();
}

class _GitBranchDialogState extends State<GitBranchDialog> {
  final _branchController = TextEditingController();
  final _baseController = TextEditingController();
  final _worktreeController = TextEditingController();
  bool _switchAfterCreate = false;
  bool _newBranchWorktree = false;
  bool _creatingBranch = false;
  bool _creatingWorktree = false;
  String _query = '';

  @override
  void dispose() {
    _branchController.dispose();
    _baseController.dispose();
    _worktreeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final projectId = state.gitDialogProjectId;
    if (projectId == null) return const SizedBox.shrink();
    final repo = state.gitRepoInfo(projectId);
    final branches = state.gitBranches(projectId);
    final worktrees = state.gitWorktrees(projectId);

    return Stack(
      children: [
        ModalBarrier(
          color: Colors.black.withValues(alpha: 0.5),
          dismissible: false,
        ),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560, maxHeight: 720),
            child: Card(
              margin: const EdgeInsets.all(24),
              elevation: 3,
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildHeader(context, repo),
                    const SizedBox(height: 16),
                    if (repo == null)
                      const Center(child: CircularProgressIndicator())
                    else if (!repo.isRepo)
                      _buildNotRepo(context)
                    else ...[
                      _buildSearchField(context),
                      const SizedBox(height: 12),
                      Expanded(
                        child: _BranchList(
                          branches: _filter(branches),
                          currentBranch: repo.branch,
                          onCheckout: (b) => _checkout(projectId, b),
                          onUseForThread: (b) => _useBranch(projectId, b),
                        ),
                      ),
                      const Divider(height: 32),
                      _buildCreateBranch(context, projectId),
                      const SizedBox(height: 16),
                      _buildWorktreeSection(context, projectId, branches),
                      if (worktrees.isNotEmpty) _buildWorktreeList(context, projectId, worktrees),
                    ],
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: state.closeDialog,
                          child: Text(l10n(context).cancel),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildHeader(BuildContext context, GitRepoInfo? repo) {
    final theme = Theme.of(context);
    final title = repo != null && repo.isRepo ? repo.toplevel.split('/').last : l10n(context).gitBranches;
    return Row(
      children: [
        Expanded(
          child: Text(title, style: theme.textTheme.headlineSmall),
        ),
        if (repo != null && repo.isRepo) ...[
          const SizedBox(width: 8),
          Text(repo.branch, style: theme.textTheme.labelLarge),
        ],
      ],
    );
  }

  Widget _buildNotRepo(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Text(l10n(context).notAGitRepo),
    );
  }

  Widget _buildSearchField(BuildContext context) {
    return TextField(
      decoration: InputDecoration(
        labelText: l10n(context).searchBranches,
        prefixIcon: const Icon(Icons.search),
        border: const OutlineInputBorder(),
      ),
      onChanged: (v) {
        setState(() => _query = v);
        final state = context.read<AppState>();
        final id = state.gitDialogProjectId;
        if (id != null) {
          state.loadGitBranches(id, query: v.isEmpty ? null : v);
        }
      },
    );
  }

  Widget _buildCreateBranch(BuildContext context, int projectId) {
    final state = context.read<AppState>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n(context).createBranch, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        TextField(
          controller: _branchController,
          decoration: InputDecoration(
            labelText: l10n(context).branchName,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _baseController,
          decoration: InputDecoration(
            labelText: l10n(context).baseBranchOptional,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        CheckboxListTile(
          title: Text(l10n(context).switchAfterCreate),
          value: _switchAfterCreate,
          onChanged: _creatingBranch
              ? null
              : (v) => setState(() => _switchAfterCreate = v ?? false),
          controlAffinity: ListTileControlAffinity.leading,
        ),
        FilledButton(
          onPressed: _creatingBranch ? null : () => _createBranch(state, projectId),
          child: _creatingBranch
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : Text(l10n(context).createBranch),
        ),
      ],
    );
  }

  Widget _buildWorktreeSection(BuildContext context, int projectId, List<GitBranch> branches) {
    final state = context.read<AppState>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n(context).createWorktree, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        TextField(
          controller: _worktreeController,
          decoration: InputDecoration(
            labelText: l10n(context).worktreeName,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        if (branches.isNotEmpty)
          DropdownMenu<String>(
            initialSelection: branches.firstWhere((b) => b.isCurrent, orElse: () => branches.first).name,
            requestFocusOnTap: true,
            label: Text(l10n(context).baseBranch),
            onSelected: (v) {
              if (v != null) _baseController.text = v;
            },
            dropdownMenuEntries: branches
                .map((b) => DropdownMenuEntry(value: b.name, label: b.name))
                .toList(),
          ),
        CheckboxListTile(
          title: Text(l10n(context).newBranchInWorktree),
          value: _newBranchWorktree,
          onChanged: _creatingWorktree
              ? null
              : (v) => setState(() => _newBranchWorktree = v ?? false),
          controlAffinity: ListTileControlAffinity.leading,
        ),
        FilledButton(
          onPressed: _creatingWorktree ? null : () => _createWorktree(state, projectId),
          child: _creatingWorktree
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : Text(l10n(context).createWorktree),
        ),
      ],
    );
  }

  Widget _buildWorktreeList(BuildContext context, int projectId, List<GitWorktree> worktrees) {
    final state = context.read<AppState>();
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 16),
        Text(l10n(context).worktrees, style: theme.textTheme.titleSmall),
        ...worktrees.map((w) => ListTile(
              dense: true,
              title: Text(w.branch ?? w.head),
              subtitle: Text(w.path, style: theme.textTheme.bodySmall),
              trailing: w.isMain
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => state.gitDeleteWorktree(projectId, w.path),
                    ),
              onTap: () => _useWorktree(projectId, w),
            )),
      ],
    );
  }

  List<GitBranch> _filter(List<GitBranch> branches) {
    if (_query.isEmpty) return branches;
    final q = _query.toLowerCase();
    return branches.where((b) => b.name.toLowerCase().contains(q)).toList();
  }

  Future<void> _createBranch(AppState state, int projectId) async {
    final name = _branchController.text.trim();
    if (name.isEmpty) return;
    setState(() => _creatingBranch = true);
    await state.gitCreateBranch(
      projectId,
      name,
      base: _baseController.text.trim().isEmpty ? null : _baseController.text.trim(),
      switchBranch: _switchAfterCreate,
    );
    if (mounted) {
      setState(() {
        _creatingBranch = false;
        _branchController.clear();
        _baseController.clear();
      });
    }
  }

  Future<void> _createWorktree(AppState state, int projectId) async {
    final name = _worktreeController.text.trim();
    final base = _baseController.text.trim();
    if (name.isEmpty || base.isEmpty) return;
    setState(() => _creatingWorktree = true);
    await state.gitCreateWorktree(projectId, name, base, newBranch: _newBranchWorktree);
    if (mounted) {
      setState(() {
        _creatingWorktree = false;
        _worktreeController.clear();
      });
    }
  }

  Future<void> _checkout(int projectId, GitBranch branch) async {
    final state = context.read<AppState>();
    await state.gitCheckout(projectId, branch.name);
  }

  Future<void> _useBranch(int projectId, GitBranch branch) async {
    final state = context.read<AppState>();
    final threadId = state.activeThreadId;
    if (threadId != null) {
      await state.setThreadGit(threadId, branch: branch.name);
    } else {
      await state.gitCheckout(projectId, branch.name);
    }
  }

  Future<void> _useWorktree(int projectId, GitWorktree worktree) async {
    final state = context.read<AppState>();
    final threadId = state.activeThreadId;
    if (threadId != null) {
      await state.setThreadGit(threadId, branch: worktree.branch, worktreePath: worktree.path);
    }
  }
}

class _BranchList extends StatelessWidget {
  final List<GitBranch> branches;
  final String currentBranch;
  final ValueChanged<GitBranch> onCheckout;
  final ValueChanged<GitBranch> onUseForThread;

  const _BranchList({
    required this.branches,
    required this.currentBranch,
    required this.onCheckout,
    required this.onUseForThread,
  });

  @override
  Widget build(BuildContext context) {
    if (branches.isEmpty) {
      return const Center(child: Text('No branches'));
    }
    return ListView.builder(
      shrinkWrap: true,
      itemCount: branches.length,
      itemBuilder: (context, index) {
        final b = branches[index];
        final isCurrent = b.name == currentBranch;
        return ListTile(
          dense: true,
          leading: Icon(
            isCurrent ? Icons.check_circle : Icons.call_split,
            color: isCurrent ? Theme.of(context).colorScheme.primary : null,
          ),
          title: Text(b.name),
          subtitle: b.isRemote ? const Text('remote') : null,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton(
                onPressed: () => onCheckout(b),
                child: const Text('Checkout'),
              ),
              TextButton(
                onPressed: () => onUseForThread(b),
                child: const Text('Use'),
              ),
            ],
          ),
        );
      },
    );
  }
}
