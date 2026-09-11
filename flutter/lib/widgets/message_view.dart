import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../l10n/l10n.dart';
import '../theme/semantic_colors.dart';

/// Severity of a transient app message.
enum MessageKind { info, success, warning, error }

const _defaultDuration = Duration(seconds: 4);
const _maxVisible = 3;

/// Shows a transient message floating above the app content.
///
/// Replaces `ScaffoldMessenger.showSnackBar`. Messages stack below the top
/// edge of the screen, an identical visible message just has its timer
/// restarted instead of stacking, and each message dismisses itself after
/// [duration].
void showAppMessage(
  BuildContext context,
  String message, {
  MessageKind kind = MessageKind.info,
  Duration duration = _defaultDuration,
}) {
  // Inserting the host entry calls setState on the overlay, which is not
  // allowed while a frame is being built, laid out, or painted.
  if (SchedulerBinding.instance.schedulerPhase ==
      SchedulerPhase.persistentCallbacks) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (context.mounted) {
        showAppMessage(context, message, kind: kind, duration: duration);
      }
    });
    return;
  }
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  _ensureHost(overlay);
  final host = _hostKey.currentState;
  if (host != null) {
    host.show(message, kind, duration);
  } else {
    // The host entry builds on a later frame after insertion; buffer the
    // message so it is picked up by the host's initState.
    _pending.add(_PendingMessage(message, kind, duration));
  }
}

/// A floating message card rendered by [showAppMessage].
class MessageView extends StatelessWidget {
  final String message;
  final MessageKind kind;
  final VoidCallback? onDismiss;

  const MessageView({
    super.key,
    required this.message,
    this.kind = MessageKind.info,
    this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final semantic = SemanticColors.of(context);

    final (icon, accent, background, foreground) = switch (kind) {
      MessageKind.info => (
        Icons.info_outline,
        semantic.info,
        semantic.infoContainer,
        semantic.onInfoContainer,
      ),
      MessageKind.success => (
        Icons.check_circle_outline,
        semantic.success,
        semantic.successContainer,
        semantic.onSuccessContainer,
      ),
      MessageKind.warning => (
        Icons.warning_amber_rounded,
        semantic.warning,
        semantic.warningContainer,
        semantic.onWarningContainer,
      ),
      MessageKind.error => (
        Icons.error_outline,
        colors.error,
        colors.errorContainer,
        colors.onErrorContainer,
      ),
    };

    return Material(
      elevation: 6,
      color: background,
      borderRadius: BorderRadius.circular(12),
      shadowColor: colors.shadow.withAlpha(60),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: accent.withValues(alpha: 0.4)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: accent),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                message,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(color: foreground),
              ),
            ),
            if (onDismiss != null) ...[
              const SizedBox(width: 8),
              Tooltip(
                message: l10n(context).close,
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: onDismiss,
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: Icon(
                      Icons.close,
                      size: 16,
                      color: foreground.withValues(alpha: 0.7),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ActiveMessage {
  final int id;
  final String text;
  final MessageKind kind;
  bool dismissed = false;

  _ActiveMessage({required this.id, required this.text, required this.kind});
}

class _PendingMessage {
  final String text;
  final MessageKind kind;
  final Duration duration;

  const _PendingMessage(this.text, this.kind, this.duration);
}

OverlayState? _hostOverlay;
OverlayEntry? _hostEntry;
GlobalKey<_MessageHostState> _hostKey = GlobalKey();
final _pending = <_PendingMessage>[];

void _ensureHost(OverlayState overlay) {
  if (identical(_hostOverlay, overlay) && _hostEntry != null) return;
  _hostEntry?.remove();
  _hostKey = GlobalKey();
  _hostEntry = OverlayEntry(builder: (_) => _MessageHost(key: _hostKey));
  overlay.insert(_hostEntry!);
  _hostOverlay = overlay;
}

/// The single overlay entry that renders the stack of live messages.
class _MessageHost extends StatefulWidget {
  const _MessageHost({super.key});

  @override
  State<_MessageHost> createState() => _MessageHostState();
}

class _MessageHostState extends State<_MessageHost> {
  final _messages = <_ActiveMessage>[];
  final _timers = <int, Timer>{};
  int _nextId = 0;

  @override
  void initState() {
    super.initState();
    for (final pending in _pending) {
      show(pending.text, pending.kind, pending.duration);
    }
    _pending.clear();
  }

  @override
  void dispose() {
    for (final timer in _timers.values) {
      timer.cancel();
    }
    super.dispose();
  }

  void show(String text, MessageKind kind, Duration duration) {
    // Restart the timer when an identical message is already visible.
    for (final message in _messages) {
      if (!message.dismissed && message.text == text && message.kind == kind) {
        _timers[message.id]?.cancel();
        _timers[message.id] = Timer(duration, () => _dismiss(message.id));
        return;
      }
    }
    final visible = _messages.where((m) => !m.dismissed).toList();
    if (visible.length >= _maxVisible) {
      _dismiss(visible.first.id);
    }
    final id = _nextId++;
    setState(() {
      _messages.add(_ActiveMessage(id: id, text: text, kind: kind));
    });
    _timers[id] = Timer(duration, () => _dismiss(id));
  }

  void _dismiss(int id) {
    if (!mounted) return;
    final index = _messages.indexWhere((m) => m.id == id);
    if (index == -1 || _messages[index].dismissed) return;
    _timers.remove(id)?.cancel();
    setState(() => _messages[index].dismissed = true);
  }

  void _remove(int id) {
    if (!mounted) return;
    setState(() => _messages.removeWhere((m) => m.id == id));
  }

  @override
  Widget build(BuildContext context) {
    if (_messages.isEmpty) return const SizedBox.shrink();
    return SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: math.min(
              440.0,
              math.max(0.0, MediaQuery.sizeOf(context).width - 32),
            ),
            maxHeight: MediaQuery.sizeOf(context).height * 0.6,
          ),
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final message in _messages)
                    _MessageEntry(
                      key: ValueKey(message.id),
                      message: message,
                      onDismiss: () => _dismiss(message.id),
                      onDismissed: () => _remove(message.id),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A single message that animates in on mount and out when its record is
/// marked dismissed.
class _MessageEntry extends StatefulWidget {
  final _ActiveMessage message;
  final VoidCallback onDismiss;
  final VoidCallback onDismissed;

  const _MessageEntry({
    super.key,
    required this.message,
    required this.onDismiss,
    required this.onDismissed,
  });

  @override
  State<_MessageEntry> createState() => _MessageEntryState();
}

class _MessageEntryState extends State<_MessageEntry>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    reverseDuration: const Duration(milliseconds: 160),
  )..forward();
  late final _animation = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );
  bool _closing = false;

  @override
  void didUpdateWidget(covariant _MessageEntry oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.message.dismissed) _close();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _close() {
    if (_closing) return;
    _closing = true;
    _controller.reverse().then((_) {
      if (mounted) widget.onDismissed();
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.message.dismissed) _close();
    return SizeTransition(
      sizeFactor: _animation,
      alignment: Alignment.topCenter,
      child: FadeTransition(
        opacity: _animation,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, -0.4),
            end: Offset.zero,
          ).animate(_animation),
          child: Semantics(
            liveRegion: true,
            // The gap lives inside the size transition so it collapses
            // together with the message on the way out.
            child: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: MessageView(
                message: widget.message.text,
                kind: widget.message.kind,
                onDismiss: widget.onDismiss,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
