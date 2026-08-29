part of '../thread_page.dart';

/// The chat view: a scrollable message list on top, and a fixed composer
/// at the bottom. The composer never scrolls off-screen because it lives
/// outside the messages' scroll view.
class ChatView extends StatefulWidget {
  const ChatView({super.key});

  @override
  State<ChatView> createState() => _ChatViewState();
}

@immutable
class _ChatModel {
  final String? activeThreadId;
  final ThreadDetail? detail;
  final bool loading;
  final int messageCount;
  final int streamingDigest;
  final bool streamingThinkingActive;
  final String? pendingAskRequestId;

  const _ChatModel({
    required this.activeThreadId,
    required this.detail,
    required this.loading,
    required this.messageCount,
    required this.streamingDigest,
    required this.streamingThinkingActive,
    required this.pendingAskRequestId,
  });

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! _ChatModel) return false;
    return activeThreadId == other.activeThreadId &&
        detail == other.detail &&
        loading == other.loading &&
        messageCount == other.messageCount &&
        streamingDigest == other.streamingDigest &&
        streamingThinkingActive == other.streamingThinkingActive &&
        pendingAskRequestId == other.pendingAskRequestId;
  }

  @override
  int get hashCode => Object.hash(
    activeThreadId,
    detail,
    loading,
    messageCount,
    streamingDigest,
    streamingThinkingActive,
    pendingAskRequestId,
  );
}

@immutable
class _PlanOverlayModel {
  final Plan? plan;
  final bool expanded;
  final bool dismissed;

  const _PlanOverlayModel({
    this.plan,
    required this.expanded,
    required this.dismissed,
  });

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! _PlanOverlayModel) return false;
    return plan == other.plan &&
        expanded == other.expanded &&
        dismissed == other.dismissed;
  }

  @override
  int get hashCode => Object.hash(plan, expanded, dismissed);
}

class _ChatViewState extends State<ChatView> {
  static const _loadMoreThreshold = 800.0;
  static const _autoScrollThreshold = 80.0;

  final _scrollController = ScrollController();
  final _composerController = TextEditingController();
  bool _autoScroll = true;
  int _lastMessageCount = 0;
  int _lastStreamingDigest = 0;
  String? _lastThreadId;
  bool _loadingMore = false;
  bool _jumpingAfterLoad = false;
  ScrollPosition? _scrollPosition;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(() {
      if (!_scrollController.hasClients) return;
      final position = _scrollController.position;
      _autoScroll = position.pixels < _autoScrollThreshold;
      _attachScrollEndListener(position);
    });
  }

  void _attachScrollEndListener(ScrollPosition position) {
    if (_scrollPosition == position) return;
    _scrollPosition?.isScrollingNotifier.removeListener(_onScrollEnd);
    _scrollPosition = position;
    _scrollPosition!.isScrollingNotifier.addListener(_onScrollEnd);
  }

  void _onScrollEnd() {
    if (_scrollPosition == null || _scrollPosition!.isScrollingNotifier.value) {
      return;
    }
    if (_jumpingAfterLoad) {
      _jumpingAfterLoad = false;
      return;
    }
    final position = _scrollPosition!;
    final max = position.maxScrollExtent;
    final pos = position.pixels;
    final distFromTop = max - pos;
    if (distFromTop < _loadMoreThreshold &&
        pos > 0 &&
        max > _loadMoreThreshold &&
        !_loadingMore) {
      _loadMore();
    }
  }

  void _loadMore() {
    if (!mounted) return;
    final state = context.read<AppState>();
    final threadId = state.activeThreadId;
    if (threadId == null) return;
    _loadingMore = true;
    final oldMax = _scrollController.position.maxScrollExtent;
    state.loadMoreMessages().whenComplete(() {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scrollController.hasClients) {
          _loadingMore = false;
          return;
        }
        final newState = context.read<AppState>();
        if (newState.activeThreadId != threadId) {
          _loadingMore = false;
          return;
        }
        try {
          final newPos = _scrollController.position.pixels;
          final newMax = _scrollController.position.maxScrollExtent;
          final delta = newMax - oldMax;
          // Only adjust if the user is still near the top from before load.
          if (delta > 0 && newPos >= oldMax - _loadMoreThreshold) {
            _jumpingAfterLoad = true;
            _scrollController.jumpTo((newPos + delta).clamp(0, newMax));
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _jumpingAfterLoad = false;
            });
          }
        } finally {
          _loadingMore = false;
        }
      });
    });
  }

  @override
  void dispose() {
    _scrollPosition?.isScrollingNotifier.removeListener(_onScrollEnd);
    _scrollController.dispose();
    _composerController.dispose();
    super.dispose();
  }

  void _maybeScrollToBottom({bool force = false}) {
    if (!force && !_autoScroll) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.jumpTo(0);
      // Reversed ListView may correct the scroll offset after the initial
      // jump when a new child is laid out. Give the next frame a chance to
      // settle and snap back if it drifted above the auto-scroll threshold.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scrollController.hasClients) return;
        if (_autoScroll &&
            _scrollController.position.pixels > _autoScrollThreshold) {
          _scrollController.jumpTo(0);
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return Selector<AppState, _ChatModel>(
      selector: (_, state) => _ChatModel(
        activeThreadId: state.activeThreadId,
        detail: state.activeThreadDetail,
        loading: state.activeThreadLoading,
        messageCount: state.activeThreadDetail?.messages.length ?? 0,
        streamingDigest: _streamingDigest(state.streamingParts),
        streamingThinkingActive: state.streamingThinkingActive,
        pendingAskRequestId: state.pendingAskRequest?.requestId,
      ),
      shouldRebuild: (prev, next) => prev != next,
      builder: (context, model, child) {
        final state = context.read<AppState>();

        final msgCount = model.messageCount;
        final newMessage = msgCount != _lastMessageCount;
        final newParts = model.streamingDigest != _lastStreamingDigest;
        if (newMessage || newParts) {
          // Keep the view at the bottom while the user is actively sending.
          if (newMessage && state.sending) _autoScroll = true;
          _maybeScrollToBottom(force: newMessage && state.sending);
        }
        _lastMessageCount = msgCount;
        _lastStreamingDigest = model.streamingDigest;

        final threadId = model.activeThreadId;
        if (threadId != _lastThreadId) {
          _lastThreadId = threadId;
          _autoScroll = true;
          _maybeScrollToBottom(force: true);
        }

        return Column(
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _MessagesPanel(
                    detail: model.detail,
                    loading: model.loading,
                    streamingParts: state.streamingParts,
                    streamingThinkingActive: model.streamingThinkingActive,
                    controller: _scrollController,
                  ),
                  Positioned(
                    top: 16,
                    left: 16,
                    right: 16,
                    child: _PlanOverlay(),
                  ),
                ],
              ),
            ),
            if (model.pendingAskRequestId != null)
              AskRequestPanel(key: ValueKey(model.pendingAskRequestId))
            else if (!model.loading) ...[
              if (state.sending)
                Padding(
                  padding: const EdgeInsets.fromLTRB(32, 0, 24, 4),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: ElapsedTimeIndicator(
                      key: ValueKey(state.startedAt),
                      startedAt: state.startedAt,
                      active: state.sending,
                    ),
                  ),
                ),
              _Composer(controller: _composerController),
              const BranchToolbar(),
            ],
          ],
        );
      },
    );
  }
}
