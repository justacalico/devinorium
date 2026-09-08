part of '../settings_page.dart';

/// Usage settings topic: token/cost totals for the current server, a
/// per-day bar strip, and per-provider / per-model breakdowns. Data is
/// recorded by the backend, so every connected machine sees the same numbers.
class _UsageSection extends StatefulWidget {
  final AppState state;

  const _UsageSection({required this.state});

  @override
  State<_UsageSection> createState() => _UsageSectionState();
}

class _UsageSectionState extends State<_UsageSection> {
  static const _windows = [7, 30, 90];

  int _days = 30;
  Future<UsageSummary>? _future;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _future = widget.state.api.usageSummary(days: _days);
  }

  void _setDays(int days) {
    if (days == _days) return;
    setState(() {
      _days = days;
      _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = l10n(context);

    return _SectionCard(
      title: l.usage,
      children: [
        Text(
          l.usageDescription,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SegmentedButton<int>(
            segments: [
              for (final d in _windows)
                ButtonSegment<int>(value: d, label: Text(l.usageLastDays(d))),
            ],
            selected: {_days},
            onSelectionChanged: (s) => _setDays(s.first),
            showSelectedIcon: false,
          ),
        ),
        const SizedBox(height: 16),
        FutureBuilder<UsageSummary>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snapshot.hasError) {
              return _UsageError(
                label: l.usageLoadFailed,
                onRetry: () => setState(_load),
              );
            }
            final summary = snapshot.data;
            if (summary == null || summary.buckets.isEmpty) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  l.usageEmpty,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              );
            }
            return _UsageBody(summary: summary, days: _days);
          },
        ),
      ],
    );
  }
}

class _UsageError extends StatelessWidget {
  final String label;
  final VoidCallback onRetry;

  const _UsageError({required this.label, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ),
        TextButton.icon(
          onPressed: onRetry,
          icon: const Icon(Icons.refresh, size: 18),
          label: Text(l10n(context).retry),
        ),
      ],
    );
  }
}

class _UsageBody extends StatelessWidget {
  final UsageSummary summary;
  final int days;

  const _UsageBody({required this.summary, required this.days});

  @override
  Widget build(BuildContext context) {
    final l = l10n(context);
    final totals = summary.totals;
    final cached = totals.cachedReadTokens + totals.cachedWriteTokens;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _StatChip(
              label: l.usageTotalTokens,
              value: formatTokens(totals.totalTokens),
            ),
            _StatChip(
              label: l.usageInput,
              value: formatTokens(totals.inputTokens),
            ),
            _StatChip(
              label: l.usageOutput,
              value: formatTokens(totals.outputTokens),
            ),
            if (cached > 0)
              _StatChip(label: l.usageCached, value: formatTokens(cached)),
            if (totals.thoughtTokens > 0)
              _StatChip(
                label: l.usageReasoning,
                value: formatTokens(totals.thoughtTokens),
              ),
            _StatChip(label: l.usageTurns, value: '${totals.records}'),
            for (final cost in totals.costs)
              _StatChip(
                label: l.usageCost,
                value: _formatCost(cost.amount, cost.currency),
              ),
          ],
        ),
        const SizedBox(height: 20),
        Text(l.usageByDay, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        _DailyUsageChart(summary: summary, days: days),
        const SizedBox(height: 20),
        _UsageBreakdown(
          title: l.usageByProvider,
          rows: _groupBy(summary.buckets, (b) => b.providerId),
          labelFor: (key) => _providerName(context, key),
        ),
        const SizedBox(height: 12),
        _UsageBreakdown(
          title: l.usageByModel,
          rows: _groupBy<({String provider, String model})>(
            summary.buckets,
            (b) => (provider: b.providerId, model: b.model),
          ),
          labelFor: (key) =>
              '${key.model} · ${_providerName(context, key.provider)}',
        ),
      ],
    );
  }

  static String _formatCost(double amount, String currency) {
    if (currency == 'USD') return '\$${amount.toStringAsFixed(2)}';
    return '${amount.toStringAsFixed(2)} $currency';
  }

  static String _providerName(BuildContext context, String providerId) {
    final providers = context.read<AppState>().providers;
    for (final p in providers) {
      if (p.id == providerId) return p.name;
    }
    return providerId;
  }

  /// Sum buckets into `key -> tokens`, sorted by tokens descending. Buckets
  /// are already split by currency, so a group only keeps a cost when every
  /// merged row reports the same currency.
  static List<_UsageRow<K>> _groupBy<K>(
    List<UsageBucket> buckets,
    K Function(UsageBucket) keyOf,
  ) {
    final map = <K, _UsageRow<K>>{};
    for (final b in buckets) {
      final key = keyOf(b);
      final prev = map[key];
      final mixed = prev != null && prev.currency != b.costCurrency;
      map[key] = _UsageRow(
        key: key,
        tokens: (prev?.tokens ?? 0) + b.totalTokens,
        cost: mixed ? 0 : (prev?.cost ?? 0) + (b.costAmount ?? 0),
        currency: mixed ? null : b.costCurrency,
      );
    }
    return map.values.toList()..sort((a, b) => b.tokens.compareTo(a.tokens));
  }
}

class _UsageRow<K> {
  final K key;
  final int tokens;
  final double cost;
  final String? currency;

  const _UsageRow({
    required this.key,
    required this.tokens,
    required this.cost,
    required this.currency,
  });
}

/// A compact stat chip: label over value.
class _StatChip extends StatelessWidget {
  final String label;
  final String value;

  const _StatChip({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// Total-tokens-per-day bar strip covering the whole window, including days
/// with zero usage so the timeline stays continuous.
class _DailyUsageChart extends StatelessWidget {
  final UsageSummary summary;
  final int days;

  const _DailyUsageChart({required this.summary, required this.days});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final perDay = <String, int>{};
    for (final b in summary.buckets) {
      perDay[b.day] = (perDay[b.day] ?? 0) + b.totalTokens;
    }
    final maxTokens = perDay.values.fold(0, (a, b) => a > b ? a : b);

    final dayList = _enumerateDays(summary.sinceDay, summary.untilDay);

    const barHeight = 96.0;
    return SizedBox(
      height: barHeight + 20,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        reverse: true,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (final day in dayList)
              _UsageBar(
                day: day,
                tokens: perDay[day] ?? 0,
                maxTokens: maxTokens,
                barHeight: barHeight,
                color: theme.colorScheme.primary,
                trackColor: theme.colorScheme.surfaceContainerHighest,
              ),
          ],
        ),
      ),
    );
  }

  /// Inclusive `YYYY-MM-DD` day list between two bounds.
  static List<String> _enumerateDays(String since, String until) {
    final start = DateTime.tryParse(since);
    final end = DateTime.tryParse(until);
    if (start == null || end == null || end.isBefore(start)) {
      return const [];
    }
    final days = <String>[];
    for (
      var d = DateTime.utc(start.year, start.month, start.day);
      !d.isAfter(end);
      d = d.add(const Duration(days: 1))
    ) {
      days.add(
        '${d.year.toString().padLeft(4, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}',
      );
    }
    return days;
  }
}

class _UsageBar extends StatelessWidget {
  final String day;
  final int tokens;
  final int maxTokens;
  final double barHeight;
  final Color color;
  final Color trackColor;

  const _UsageBar({
    required this.day,
    required this.tokens,
    required this.maxTokens,
    required this.barHeight,
    required this.color,
    required this.trackColor,
  });

  @override
  Widget build(BuildContext context) {
    final fraction = maxTokens > 0 ? tokens / maxTokens : 0.0;
    final height = tokens > 0
        ? (barHeight * fraction).clamp(3.0, barHeight)
        : 3.0;
    return Tooltip(
      message: '$day · ${formatTokens(tokens)}',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Container(
              width: 10,
              height: height,
              decoration: BoxDecoration(
                color: tokens > 0 ? color : trackColor,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              day.length >= 10 ? day.substring(8) : day,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A labeled list of per-key token shares with thin progress bars.
class _UsageBreakdown<K> extends StatelessWidget {
  final String title;
  final List<_UsageRow<K>> rows;
  final String Function(K key) labelFor;

  const _UsageBreakdown({
    required this.title,
    required this.rows,
    required this.labelFor,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = l10n(context);
    final maxTokens = rows.fold(0, (a, r) => r.tokens > a ? r.tokens : a);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        for (final row in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        labelFor(row.key),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                    const SizedBox(width: 12),
                    if (row.cost > 0 && row.currency != null) ...[
                      Text(
                        _UsageBody._formatCost(row.cost, row.currency!),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    Text(
                      formatTokens(row.tokens),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: maxTokens > 0 ? row.tokens / maxTokens : 0,
                    minHeight: 4,
                    backgroundColor: theme.colorScheme.surfaceContainerHighest,
                  ),
                ),
              ],
            ),
          ),
        if (rows.isEmpty)
          Text(
            l.usageEmpty,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
      ],
    );
  }
}
