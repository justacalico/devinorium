import 'dart:async';

import 'package:flutter/material.dart';

/// A small badge that shows how long the current run has been going, like
/// t3code's "Working for 12s" indicator. Ticks every second via a [Timer]
/// while visible, and stops when the parent stops rebuilding it.
class ElapsedTimeIndicator extends StatefulWidget {
  final String? startedAt;
  final bool active;

  const ElapsedTimeIndicator({
    super.key,
    required this.startedAt,
    required this.active,
  });

  @override
  State<ElapsedTimeIndicator> createState() => _ElapsedTimeIndicatorState();
}

class _ElapsedTimeIndicatorState extends State<ElapsedTimeIndicator> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    if (widget.active && widget.startedAt != null) _startTimer();
  }

  @override
  void didUpdateWidget(covariant ElapsedTimeIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    final shouldTick = widget.active && widget.startedAt != null;
    if (shouldTick) {
      _startTimer();
    } else {
      _stopTimer();
    }
  }

  void _startTimer() {
    if (_timer?.isActive ?? false) return;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void dispose() {
    _stopTimer();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final startedAt = widget.startedAt;

    if (!widget.active || startedAt == null) return const SizedBox.shrink();

    final start = DateTime.tryParse(startedAt);
    if (start == null) return const SizedBox.shrink();

    final elapsed = DateTime.now().toUtc().difference(start);
    final label = _formatDuration(elapsed);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 10,
            height: 10,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              valueColor: AlwaysStoppedAnimation(theme.colorScheme.primary),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  String _formatDuration(Duration d) {
    final s = d.inSeconds;
    if (s < 60) return '${s}s';
    final m = d.inMinutes;
    final rem = s % 60;
    if (m < 60) return rem == 0 ? '${m}m' : '${m}m ${rem}s';
    final h = d.inHours;
    final remM = m % 60;
    return remM == 0 ? '${h}h' : '${h}h ${remM}m';
  }
}
