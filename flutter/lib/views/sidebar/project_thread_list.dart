part of '../sidebar.dart';

/// A combined list of projects, each expandable to show its threads.
class _ProjectThreadList extends StatefulWidget {
  const _ProjectThreadList();

  @override
  State<_ProjectThreadList> createState() => _ProjectThreadListState();
}

class _ProjectThreadListState extends State<_ProjectThreadList> {
  final Set<int> _expandedIds = {};
  int? _lastActiveProjectId;
  String? _lastActiveThreadId;
  List<Thread> _lastThreads = [];
  Timer? _pollTimer;
  final ScrollController _scrollController = ScrollController();
  static const _loadMoreThreshold = 200.0;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _pollTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) {
        if (mounted) context.read<AppState>().refreshRunningThreads();
      },
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<AppState>().refreshRunningThreads();
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final state = context.read<AppState>();
    final pos = _scrollController.position;
    if (state.hasMoreProjects &&
        !state.isLoadingMoreProjects &&
        pos.pixels >= pos.maxScrollExtent - _loadMoreThreshold) {
      state.loadMoreProjects();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final state = context.read<AppState>();
    final activeProjectId = state.activeProjectId;
    final activeThreadId = state.activeThreadId;
    final threads = state.threads;
    final projects = state.projects;

    if (activeThreadId != _lastActiveThreadId ||
        activeProjectId != _lastActiveProjectId ||
        threads != _lastThreads) {
      _lastActiveThreadId = activeThreadId;
      _lastActiveProjectId = activeProjectId;
      _lastThreads = threads;

      // On initial load no thread is selected, so all projects start collapsed.
      // When a thread becomes active, expand the project that owns it.
      if (activeThreadId != null) {
        final projectId = _projectIdForThread(threads, activeThreadId) ??
            activeProjectId;
        if (projectId != null && !_expandedIds.contains(projectId)) {
          setState(() {
            _expandedIds.add(projectId);
          });
        }
      }
    }

    _expandedIds.removeWhere((id) => !projects.any((p) => p.id == id));
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final projects = state.projects;
    final threads = state.threads;
    final activeThreadId = state.activeThreadId;

    if (projects.isEmpty) {
      return const _NoProjects();
    }

    final threadsByProject = <int, List<Thread>>{};
    for (final t in threads) {
      if (t.projectId != 0) {
        threadsByProject.putIfAbsent(t.projectId, () => []).add(t);
      }
    }
    for (final list in threadsByProject.values) {
      list.sort((a, b) {
        if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
        return b.updatedAt.compareTo(a.updatedAt);
      });
    }

    return Column(
      children: [
        Expanded(
          child: ReorderableListView.builder(
            scrollController: _scrollController,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            buildDefaultDragHandles: false,
            onReorderItem: _onReorder,
            itemCount: projects.length,
            itemBuilder: (context, index) {
              final p = projects[index];
              return _ProjectExpandableTile(
                key: ValueKey(p.id),
                index: index,
                project: p,
                threads: threadsByProject[p.id] ?? [],
                isExpanded: _expandedIds.contains(p.id),
                activeThreadId: activeThreadId,
                onToggle: () => _onToggle(p.id),
                onNewThread: () {
                  Scaffold.of(context).closeDrawer();
                  state.createNewThread(projectId: p.id);
                },
                onThreadTap: (id) => state.openThread(id),
              );
            },
          ),
        ),
        if (state.hasMoreProjects || state.isLoadingMoreProjects)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: state.isLoadingMoreProjects
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : TextButton(
                    onPressed: () => state.loadMoreProjects(),
                    child: const Text('Load more'),
                  ),
          ),
      ],
    );
  }

  void _onReorder(int oldIndex, int newIndex) {
    final state = context.read<AppState>();
    final ids = state.projects.map((p) => p.id).toList();
    final moved = ids.removeAt(oldIndex);
    ids.insert(newIndex, moved);
    state.reorderProjects(ids);
  }

  void _onToggle(int id) {
    final state = context.read<AppState>();
    if (_expandedIds.contains(id)) {
      setState(() {
        _expandedIds.remove(id);
      });
    } else {
      setState(() {
        _expandedIds.add(id);
      });
      state.selectProject(id);
    }
  }

  int? _projectIdForThread(List<Thread> threads, String threadId) {
    for (final t in threads) {
      if (t.id == threadId) return t.projectId;
    }
    return null;
  }
}
