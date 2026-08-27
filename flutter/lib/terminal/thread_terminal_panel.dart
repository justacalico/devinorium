import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../api/api_service.dart';
import '../l10n/l10n.dart';
import 'terminal_session.dart';
import 'terminal_tabs.dart';

/// A resizable bottom panel that hosts one or more terminal sessions for a
/// thread, similar to the bottom terminal drawer in t3code.
///
/// The panel is keyed by [threadId] internally: sessions are kept per thread
/// and survive thread switches and hide/show toggles.
class ThreadTerminalPanel extends StatefulWidget {
  const ThreadTerminalPanel({
    super.key,
    required this.api,
    required this.threadId,
    this.open = true,
    this.initialHeight = _defaultHeight,
    this.onHeightChanged,
    this.onClose,
    this.sessionFactory = createTerminalSession,
  });

  final ApiService api;
  final String threadId;
  final bool open;
  final double initialHeight;
  final ValueChanged<double>? onHeightChanged;
  final VoidCallback? onClose;
  final TerminalSessionFactory sessionFactory;

  static const _defaultHeight = 280.0;

  @override
  State<ThreadTerminalPanel> createState() => _ThreadTerminalPanelState();
}

class _ThreadData {
  final sessions = <TerminalSession>[];
  bool busy = false;
  int activeIndex = 0;
}

class _ThreadTerminalPanelState extends State<ThreadTerminalPanel> {
  final _data = <String, _ThreadData>{};
  final _heights = <String, double>{};
  final _sessionThreads = <TerminalSession, String>{};
  bool _dragging = false;

  static const _minHeight = 180.0;
  static const _maxHeightRatio = 0.75;

  bool get _canUseLocalTerminal =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.windows);

  _ThreadData _dataFor(String threadId) =>
      _data.putIfAbsent(threadId, () => _ThreadData());

  @override
  void initState() {
    super.initState();
    _heights[widget.threadId] = widget.initialHeight;
  }

  @override
  void didUpdateWidget(covariant ThreadTerminalPanel old) {
    super.didUpdateWidget(old);
    if ((old.threadId != widget.threadId ||
            old.initialHeight != widget.initialHeight) &&
        !_dragging) {
      _heights[widget.threadId] = widget.initialHeight;
    }
  }

  @override
  void dispose() {
    for (final session in _sessionThreads.keys) {
      session.removeListener(_onSessionUpdate);
      session.dispose();
    }
    _data.clear();
    _heights.clear();
    _sessionThreads.clear();
    super.dispose();
  }

  Future<void> _addSession({required bool local}) async {
    final threadId = widget.threadId;
    final data = _dataFor(threadId);
    if (data.busy) return;
    data.busy = true;
    if (mounted) setState(() {});
    try {
      final session = await widget.sessionFactory(
        api: widget.api,
        threadId: threadId,
        local: local,
      );
      session.addListener(_onSessionUpdate);
      _sessionThreads[session] = threadId;
      data.sessions.add(session);
      data.activeIndex = data.sessions.length - 1;
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to start terminal: $e')),
        );
      }
    } finally {
      data.busy = false;
      if (mounted) setState(() {});
    }
  }

  void _onSessionUpdate() => setState(() {});

  void _removeSession(TerminalSession session) {
    final threadId = _sessionThreads.remove(session);
    if (threadId == null) return;
    final data = _dataFor(threadId);
    if (!data.sessions.remove(session)) return;
    if (data.activeIndex >= data.sessions.length) {
      data.activeIndex = data.sessions.isEmpty ? 0 : data.sessions.length - 1;
    }
    session.removeListener(_onSessionUpdate);
    if (mounted) setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) => session.dispose());
  }

  void _setActiveTab(int index, String threadId) {
    final data = _dataFor(threadId);
    if (data.activeIndex == index) return;
    data.activeIndex = index;
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Visibility(
      visible: widget.open,
      maintainState: true,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final data = _dataFor(widget.threadId);
          final maxHeight = (constraints.maxHeight * _maxHeightRatio)
              .clamp(_minHeight, constraints.maxHeight);
          final height = (_heights[widget.threadId] ??
                  ThreadTerminalPanel._defaultHeight)
              .clamp(_minHeight, maxHeight);

          return SizedBox(
            height: height,
            child: Column(
              children: [
                _DragHandle(
                  onDragStart: () => _dragging = true,
                  onDragUpdate: (delta) {
                    setState(() {
                      _heights[widget.threadId] =
                          (_heights[widget.threadId] ??
                                  ThreadTerminalPanel._defaultHeight)
                              .clamp(_minHeight, maxHeight) -
                          delta;
                      _heights[widget.threadId] =
                          _heights[widget.threadId]!
                              .clamp(_minHeight, maxHeight);
                    });
                  },
                  onDragEnd: () {
                    _dragging = false;
                    widget.onHeightChanged?.call(
                      _heights[widget.threadId] ??
                          ThreadTerminalPanel._defaultHeight,
                    );
                  },
                ),
                _Header(
                  title: l10n(context).terminal,
                  local: _canUseLocalTerminal,
                  busy: data.busy,
                  onAddLocal: _canUseLocalTerminal
                      ? () => _addSession(local: true)
                      : null,
                  onAddRemote: () => _addSession(local: false),
                  onClose: widget.onClose,
                ),
                Divider(height: 1, color: colorScheme.outlineVariant),
                Expanded(
                  child: TerminalTabs(
                    sessions: data.sessions,
                    activeIndex: data.activeIndex,
                    onActiveIndexChanged: (index) =>
                        _setActiveTab(index, widget.threadId),
                    onClose: _removeSession,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _DragHandle extends StatelessWidget {
  const _DragHandle({
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  final VoidCallback onDragStart;
  final ValueChanged<double> onDragUpdate;
  final VoidCallback onDragEnd;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return GestureDetector(
      key: const ValueKey('terminalDragHandle'),
      behavior: HitTestBehavior.translucent,
      onVerticalDragStart: (_) => onDragStart(),
      onVerticalDragUpdate: (details) => onDragUpdate(details.delta.dy),
      onVerticalDragEnd: (_) => onDragEnd(),
      onVerticalDragCancel: onDragEnd,
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

class _Header extends StatelessWidget {
  const _Header({
    required this.title,
    required this.local,
    required this.busy,
    this.onAddLocal,
    required this.onAddRemote,
    this.onClose,
  });

  final String title;
  final bool local;
  final bool busy;
  final VoidCallback? onAddLocal;
  final VoidCallback onAddRemote;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      color: Theme.of(context).colorScheme.surface,
      child: Row(
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const Spacer(),
          if (local)
            IconButton(
              key: const ValueKey('addLocalTerminal'),
              icon: const Icon(Icons.computer, size: 20),
              tooltip: 'Local terminal',
              onPressed: busy ? null : onAddLocal,
            ),
          IconButton(
            key: const ValueKey('addRemoteTerminal'),
            icon: const Icon(Icons.cloud, size: 20),
            tooltip: 'Remote terminal',
            onPressed: busy ? null : onAddRemote,
          ),
          if (onClose != null)
            IconButton(
              icon: const Icon(Icons.keyboard_arrow_down, size: 20),
              tooltip: 'Hide terminal',
              onPressed: onClose,
            ),
        ],
      ),
    );
  }
}
