import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../merge_request/merge_request_models.dart';
import '../state/async_value.dart';
import '../utils/job_log_formatter.dart';

/// Shows the live, auto-updating trace for a CI/CD job.
///
/// The dialog polls [onLoad] while the job is live and stops once it reaches
/// a terminal status.
class JobLogDialog extends StatefulWidget {
  final MergeRequestPipelineJob job;
  final Future<JobLog> Function() onLoad;
  final VoidCallback? onOpenInBrowser;
  final Duration pollInterval;

  const JobLogDialog({
    super.key,
    required this.job,
    required this.onLoad,
    this.onOpenInBrowser,
    this.pollInterval = const Duration(seconds: 3),
  });

  @override
  State<JobLogDialog> createState() => _JobLogDialogState();
}

class _JobLogDialogState extends State<JobLogDialog> {
  final _scrollController = ScrollController();
  AsyncValue<JobLog> _value = const AsyncValue.empty();
  Object? _lastError;
  Timer? _timer;
  bool _loading = false;
  int _consecutiveErrors = 0;
  int _requestGeneration = 0;

  static const int _maxConsecutiveErrors = 3;

  @override
  void initState() {
    super.initState();
    _value = const AsyncValue.loading();
    _load(silent: true);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!mounted || _loading) return;
    final generation = ++_requestGeneration;
    _loading = true;
    _lastError = null;

    if (silent) {
      if (_value.isEmpty) {
        _value = const AsyncValue.loading();
      }
    } else {
      if (generation == _requestGeneration) {
        setState(() {
          if (!_value.isReady) {
            _value = const AsyncValue.loading();
          }
        });
      }
    }

    final previous = _value.valueOrNull;

    try {
      final log = await widget.onLoad();
      if (!mounted || generation != _requestGeneration) return;
      setState(() {
        _value = AsyncValue.ready(log);
        _lastError = null;
        _consecutiveErrors = 0;
      });
      _scrollToBottom(force: previous == null);
      _manageTimer(log.job.isLive);
    } catch (e) {
      if (!mounted || generation != _requestGeneration) return;
      _consecutiveErrors++;
      setState(() {
        _lastError = e;
        if (!_value.isReady) {
          _value = AsyncValue.error(e);
        }
      });
      _manageTimer(_value.valueOrNull?.job.isLive ?? widget.job.isLive);
    } finally {
      if (mounted && generation == _requestGeneration) {
        _loading = false;
        setState(() {});
      }
    }
  }

  void _retry() {
    _consecutiveErrors = 0;
    _timer?.cancel();
    _timer = null;
    _requestGeneration++;
    _loading = false;
    _load();
  }

  void _manageTimer(bool live) {
    if (live && _consecutiveErrors < _maxConsecutiveErrors) {
      _timer ??= Timer.periodic(widget.pollInterval, (_) => _load());
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  void _scrollToBottom({bool force = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      final position = _scrollController.position;
      final max = position.maxScrollExtent;
      if (max <= 0) return;
      if (force || position.pixels >= max - 80) {
        position.jumpTo(max);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = _value.valueOrNull?.job.status ?? widget.job.status;
    final color = _statusColor(theme, status);

    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900, maxHeight: 700),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Header(
                job: widget.job,
                status: status,
                statusColor: color,
                isLive: _value.valueOrNull?.job.isLive ?? widget.job.isLive,
                onOpenInBrowser: widget.onOpenInBrowser,
              ),
              const SizedBox(height: 12),
              Expanded(child: _buildBody(theme)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_value.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    final error = _value.errorOrNull;
    if (error != null && _value.valueOrNull == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('$error', textAlign: TextAlign.center),
            const SizedBox(height: 12),
            TextButton(onPressed: _retry, child: Text(l10n(context).retry)),
          ],
        ),
      );
    }

    final log = _value.valueOrNull;
    if (log == null) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_lastError != null)
          Container(
            color: theme.colorScheme.errorContainer,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '$_lastError',
                    style: TextStyle(color: theme.colorScheme.onErrorContainer),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.refresh, size: 18),
                  tooltip: l10n(context).retry,
                  onPressed: _retry,
                ),
              ],
            ),
          ),
        if (_loading) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: _LogBody(
            trace: log.trace,
            scrollController: _scrollController,
          ),
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  final MergeRequestPipelineJob job;
  final String status;
  final Color statusColor;
  final bool isLive;
  final VoidCallback? onOpenInBrowser;

  const _Header({
    required this.job,
    required this.status,
    required this.statusColor,
    required this.isLive,
    this.onOpenInBrowser,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      children: [
        Expanded(
          child: Text(
            job.name.isNotEmpty ? job.name : status,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (isLive) ...[
          const SizedBox(width: 8),
          _LiveBadge(),
        ],
        const SizedBox(width: 8),
        Chip(
          label: Text(
            status,
            style: TextStyle(color: statusColor, fontSize: 12),
          ),
          backgroundColor: statusColor.withValues(alpha: 0.12),
          side: BorderSide.none,
          padding: EdgeInsets.zero,
          visualDensity: VisualDensity.compact,
        ),
        if (onOpenInBrowser != null) ...[
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.open_in_new, size: 18),
            tooltip: l10n(context).openInBrowser,
            onPressed: onOpenInBrowser,
          ),
        ],
        IconButton(
          icon: const Icon(Icons.close, size: 20),
          tooltip: l10n(context).close,
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ],
    );
  }
}

class _LiveBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.fiber_manual_record,
          size: 10,
          color: theme.colorScheme.error,
        ),
        const SizedBox(width: 4),
        Text(
          l10n(context).jobLogLive,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.error,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _LogBody extends StatelessWidget {
  final String trace;
  final ScrollController scrollController;

  static const int _maxTraceChars = 50000;
  static const int _tracePadding = 1024;

  const _LogBody({required this.trace, required this.scrollController});

  String _formatTrace(BuildContext context) {
    if (trace.isEmpty) return l10n(context).noJobLog;
    final raw = trace.length > _maxTraceChars + _tracePadding
        ? trace.substring(trace.length - _maxTraceChars - _tracePadding)
        : trace;
    return JobLogFormatter.normalize(raw, maxLength: _maxTraceChars);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = _formatTrace(context);

    return Container(
      color: theme.colorScheme.surfaceContainerHighest,
      child: SingleChildScrollView(
        controller: scrollController,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: SelectionArea(
            child: Text(
              text,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                height: 1.4,
              ),
              softWrap: true,
            ),
          ),
        ),
      ),
    );
  }
}

Color _statusColor(ThemeData theme, String status) {
  final lower = status.toLowerCase();
  if (lower == 'success') return Colors.green;
  if (lower == 'failed' || lower == 'failure') return theme.colorScheme.error;
  if (lower == 'running') return theme.colorScheme.primary;
  if (lower == 'pending' || lower == 'created' || lower == 'waiting_for_resource') {
    return Colors.orange;
  }
  return theme.colorScheme.onSurfaceVariant;
}
