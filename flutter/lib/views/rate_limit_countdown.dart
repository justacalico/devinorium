import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../models/models.dart';

/// Banner shown while a run is parked on a rate-limit retry: it counts down
/// to the backend-reported retry time and disappears when the wait ends.
class RateLimitCountdown extends StatefulWidget {
  final RateLimitWait wait;

  const RateLimitCountdown({super.key, required this.wait});

  @override
  State<RateLimitCountdown> createState() => _RateLimitCountdownState();
}

class _RateLimitCountdownState extends State<RateLimitCountdown> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final remaining = widget.wait.remaining;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.hourglass_top,
            size: 13,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
          Text(
            l10n(context).rateLimitedRetryingIn(_format(remaining)),
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  static String _format(Duration d) {
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
