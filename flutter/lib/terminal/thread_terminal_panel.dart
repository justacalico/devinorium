import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../api/api_service.dart';
import '../l10n/l10n.dart';
import 'terminal_grid.dart';
import 'terminal_session.dart';

/// A resizable bottom panel that hosts one or more terminal sessions for a
/// thread, similar to the bottom terminal drawer in t3code.
class ThreadTerminalPanel extends StatefulWidget {
  const ThreadTerminalPanel({
    super.key,
    required this.api,
    required this.threadId,
    this.initialHeight = _defaultHeight,
    this.onHeightChanged,
    this.onClose,
  });

  final ApiService api;
  final String threadId;
  final double initialHeight;
  final ValueChanged<double>? onHeightChanged;
  final VoidCallback? onClose;

  static const _defaultHeight = 280.0;

  @override
  State<ThreadTerminalPanel> createState() => _ThreadTerminalPanelState();
}

class _ThreadTerminalPanelState extends State<ThreadTerminalPanel> {
  final _sessions = <TerminalSession>[];
  bool _busy = false;
  bool _dragging = false;
  double _height = _ThreadTerminalPanelState._defaultHeight;

  static const _minHeight = 180.0;
  static const _maxHeightRatio = 0.75;
  static const _defaultHeight = 280.0;

  bool get _canUseLocalTerminal =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.windows);

  @override
  void initState() {
    super.initState();
    _height = widget.initialHeight;
  }

  @override
  void didUpdateWidget(covariant ThreadTerminalPanel old) {
    super.didUpdateWidget(old);
    if (old.initialHeight != widget.initialHeight && !_dragging) {
      _height = widget.initialHeight;
    }
  }

  @override
  void dispose() {
    for (final s in _sessions) {
      s.removeListener(_onSessionUpdate);
      s.dispose();
    }
    _sessions.clear();
    super.dispose();
  }

  Future<void> _addSession({required bool local}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final session = await createTerminalSession(
        api: widget.api,
        threadId: widget.threadId,
        local: local,
      );
      session.addListener(_onSessionUpdate);
      if (mounted) setState(() => _sessions.add(session));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to start terminal: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _onSessionUpdate() => setState(() {});

  void _removeSession(TerminalSession session) {
    session.removeListener(_onSessionUpdate);
    setState(() => _sessions.remove(session));
    WidgetsBinding.instance.addPostFrameCallback((_) => session.dispose());
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxHeight = (constraints.maxHeight * _maxHeightRatio)
            .clamp(_minHeight, constraints.maxHeight);
        final clampedHeight = _height.clamp(_minHeight, maxHeight);

        return SizedBox(
          height: clampedHeight,
          child: Column(
            children: [
              _DragHandle(
                onDragStart: () => _dragging = true,
                onDragUpdate: (delta) {
                  setState(() {
                    _height -= delta;
                    _height = _height.clamp(_minHeight, maxHeight);
                  });
                },
                onDragEnd: () {
                  _dragging = false;
                  widget.onHeightChanged?.call(_height);
                },
              ),
              _Header(
                title: l10n(context).terminal,
                local: _canUseLocalTerminal,
                busy: _busy,
                onAddLocal: _canUseLocalTerminal
                    ? () => _addSession(local: true)
                    : null,
                onAddRemote: () => _addSession(local: false),
                onClose: widget.onClose,
              ),
              Divider(height: 1, color: colorScheme.outlineVariant),
              Expanded(
                child: TerminalGrid(
                  sessions: _sessions,
                  onClose: _removeSession,
                ),
              ),
            ],
          ),
        );
      },
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
              icon: const Icon(Icons.computer, size: 20),
              tooltip: 'Local terminal',
              onPressed: busy ? null : onAddLocal,
            ),
          IconButton(
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
