import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import '../state/app_state.dart';
import 'browser_feed.dart';
import 'browser_store.dart';

/// Fixed remote viewport: the agent's Chromium always runs at this size
/// and the panel only scales the picture, so resizing here can never feed
/// back into the browser.
const kBrowserViewportWidth = 1280.0;
const kBrowserViewportHeight = 800.0;

/// View-only live preview of the agent's browser for the active thread.
///
/// The feed socket is created lazily while the panel is open and dropped
/// on close, thread switch, or unmount. No pointer, keyboard, or scroll
/// input is ever forwarded: there is intentionally no gesture handling on
/// the frame itself.
class BrowserPanel extends StatefulWidget {
  const BrowserPanel({
    super.key,
    required this.store,
    this.onClose,
    this.feedFactory,
  });

  final BrowserPanelStore store;

  /// Called when the user hides the panel. Defaults to closing the store.
  final VoidCallback? onClose;

  /// Injectable feed factory for tests.
  final BrowserFeedClient Function(Uri uri, String? token)? feedFactory;

  static const _maxHeightRatio = 0.5;

  @override
  State<BrowserPanel> createState() => _BrowserPanelState();
}

class _BrowserPanelState extends State<BrowserPanel> {
  BrowserFeedClient? _feed;
  String? _feedThreadId;
  int _connectGen = 0;

  Future<void> _connect(AppState state, String threadId) async {
    final gen = ++_connectGen;
    try {
      final uri = await state.api.browserWebSocketUri(threadId);
      final token = await state.api.terminalToken;
      if (!mounted || gen != _connectGen || _feedThreadId != threadId) return;
      _feed =
          widget.feedFactory?.call(uri, token) ??
          BrowserFeedClient(uri: uri, token: token);
      setState(() {});
    } catch (_) {
      // A failed URL/token lookup leaves _feed null; the panel shows its
      // empty state until the next sync (thread switch or reopen).
    }
  }

  void _syncFeed(AppState state) {
    final threadId =
        widget.store.open && state.webAccessEnabled
            ? state.activeThreadId
            : null;
    if (threadId == _feedThreadId) return;
    _feedThreadId = threadId;
    _connectGen++;
    _feed?.dispose();
    _feed = null;
    if (threadId != null) {
      _connect(state, threadId);
    }
  }

  @override
  void dispose() {
    _connectGen++;
    _feed?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    // Selecting here rebuilds when the thread or web-access flag changes;
    // the ListenableBuilder below covers open/height changes. The socket
    // sync runs inside the builder so either path re-keys the feed.
    context.select<AppState, (String?, bool)>(
      (s) => (s.activeThreadId, s.webAccessEnabled),
    );

    return ListenableBuilder(
      listenable: widget.store,
      builder: (context, _) {
        _syncFeed(state);
        if (!widget.store.open) return const SizedBox.shrink();

        return LayoutBuilder(
          builder: (context, constraints) {
            final maxHeight = math.min(
              MediaQuery.sizeOf(context).height * BrowserPanel._maxHeightRatio,
              constraints.maxHeight,
            );
            final minHeight = math.min(BrowserPanelStore.minHeight, maxHeight);
            final height = widget.store.height.clamp(minHeight, maxHeight);

            return SizedBox(
              height: height,
              child: Column(
                children: [
                  _DragHandle(
                    onDragUpdate: (delta) => widget.store.setHeight(
                      (widget.store.height - delta).clamp(minHeight, maxHeight),
                    ),
                  ),
                  Expanded(
                    child: _FeedView(
                      feed: _feed,
                      webAccessEnabled: state.webAccessEnabled,
                      onClose:
                          widget.onClose ?? () => widget.store.setOpen(false),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class _FeedView extends StatelessWidget {
  const _FeedView({
    required this.feed,
    required this.webAccessEnabled,
    required this.onClose,
  });

  final BrowserFeedClient? feed;
  final bool webAccessEnabled;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    if (!webAccessEnabled) {
      return _Chrome(
        onClose: onClose,
        child: _Empty(text: l10n(context).browserWebAccessOff),
      );
    }
    final feed = this.feed;
    if (feed == null) {
      return _Chrome(onClose: onClose, child: _Empty(text: l10n(context).browserEmpty));
    }
    return ListenableBuilder(
      listenable: feed,
      builder: (context, _) {
        final frame = feed.frame;
        return _Chrome(
          title: frame.title,
          url: frame.url,
          onClose: onClose,
          child:
              frame.frame != null
                  ? ColoredBox(
                      color: Colors.black,
                      child: Center(
                        child: FittedBox(
                          fit: BoxFit.contain,
                          child: SizedBox(
                            width: kBrowserViewportWidth,
                            height: kBrowserViewportHeight,
                            child: Image.memory(
                              frame.frame!,
                              key: const ValueKey('browserFrame'),
                              gaplessPlayback: true,
                              fit: BoxFit.fill,
                              errorBuilder: (context, error, stackTrace) =>
                                  _Empty(text: l10n(context).browserEmpty),
                            ),
                          ),
                        ),
                      ),
                    )
                  : _Empty(text: l10n(context).browserEmpty),
        );
      },
    );
  }
}

/// Browser chrome: a fixed-height header row with the page title and URL,
/// plus the viewport below. The address row is read-only text; the feed
/// carries no input channel.
class _Chrome extends StatelessWidget {
  const _Chrome({
    required this.child,
    required this.onClose,
    this.title = '',
    this.url = '',
  });

  final Widget child;
  final VoidCallback onClose;
  final String title;
  final String url;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          color: theme.colorScheme.surface,
          child: Row(
            children: [
              Icon(
                Icons.public,
                size: 16,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title.isNotEmpty
                      ? '$title - $url'
                      : (url.isNotEmpty ? url : l10n(context).browser),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              IconButton(
                tooltip: l10n(context).browserHide,
                icon: const Icon(Icons.close, size: 18),
                onPressed: onClose,
              ),
            ],
          ),
        ),
        Expanded(child: child),
      ],
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      color: theme.colorScheme.surfaceContainerLowest,
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.web_asset_off_outlined,
            size: 28,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 8),
          Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _DragHandle extends StatelessWidget {
  const _DragHandle({required this.onDragUpdate});

  final ValueChanged<double> onDragUpdate;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return GestureDetector(
      key: const ValueKey('browserDragHandle'),
      behavior: HitTestBehavior.translucent,
      onVerticalDragUpdate: (details) => onDragUpdate(details.delta.dy),
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeRow,
        child: Container(
          height: 8,
          color: colorScheme.surface,
          alignment: Alignment.center,
          child: Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: colorScheme.outline,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      ),
    );
  }
}
