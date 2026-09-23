/// Usage reporting models returned by `GET /api/usage`.
library;

/// A single `(day, provider, model)` aggregate.
class UsageBucket {
  final String day;
  final String providerId;
  final String model;
  final int records;
  final int inputTokens;
  final int outputTokens;
  final int thoughtTokens;
  final int cachedReadTokens;
  final int cachedWriteTokens;
  final int totalTokens;
  final double? costAmount;
  final String? costCurrency;

  const UsageBucket({
    required this.day,
    required this.providerId,
    required this.model,
    required this.records,
    required this.inputTokens,
    required this.outputTokens,
    required this.thoughtTokens,
    required this.cachedReadTokens,
    required this.cachedWriteTokens,
    required this.totalTokens,
    this.costAmount,
    this.costCurrency,
  });

  factory UsageBucket.fromJson(Map<String, dynamic> j) => UsageBucket(
    day: j['day'] as String? ?? '',
    providerId: j['provider_id'] as String? ?? '',
    model: j['model'] as String? ?? '',
    records: (j['records'] as num?)?.toInt() ?? 0,
    inputTokens: (j['input_tokens'] as num?)?.toInt() ?? 0,
    outputTokens: (j['output_tokens'] as num?)?.toInt() ?? 0,
    thoughtTokens: (j['thought_tokens'] as num?)?.toInt() ?? 0,
    cachedReadTokens: (j['cached_read_tokens'] as num?)?.toInt() ?? 0,
    cachedWriteTokens: (j['cached_write_tokens'] as num?)?.toInt() ?? 0,
    totalTokens: (j['total_tokens'] as num?)?.toInt() ?? 0,
    costAmount: (j['cost_amount'] as num?)?.toDouble(),
    costCurrency: j['cost_currency'] as String?,
  );
}

/// A summed cost in one currency.
class UsageCost {
  final String currency;
  final double amount;

  const UsageCost({required this.currency, required this.amount});

  factory UsageCost.fromJson(Map<String, dynamic> j) => UsageCost(
    currency: j['currency'] as String? ?? '',
    amount: (j['amount'] as num?)?.toDouble() ?? 0,
  );

  @override
  bool operator ==(Object other) =>
      other is UsageCost &&
      other.currency == currency &&
      other.amount == amount;

  @override
  int get hashCode => Object.hash(currency, amount);
}

/// Window-wide totals.
class UsageTotals {
  final int records;
  final int inputTokens;
  final int outputTokens;
  final int thoughtTokens;
  final int cachedReadTokens;
  final int cachedWriteTokens;
  final int totalTokens;
  final List<UsageCost> costs;

  const UsageTotals({
    required this.records,
    required this.inputTokens,
    required this.outputTokens,
    required this.thoughtTokens,
    required this.cachedReadTokens,
    required this.cachedWriteTokens,
    required this.totalTokens,
    required this.costs,
  });

  factory UsageTotals.fromJson(Map<String, dynamic> j) {
    final rawCosts = j['costs'];
    return UsageTotals(
      records: (j['records'] as num?)?.toInt() ?? 0,
      inputTokens: (j['input_tokens'] as num?)?.toInt() ?? 0,
      outputTokens: (j['output_tokens'] as num?)?.toInt() ?? 0,
      thoughtTokens: (j['thought_tokens'] as num?)?.toInt() ?? 0,
      cachedReadTokens: (j['cached_read_tokens'] as num?)?.toInt() ?? 0,
      cachedWriteTokens: (j['cached_write_tokens'] as num?)?.toInt() ?? 0,
      totalTokens: (j['total_tokens'] as num?)?.toInt() ?? 0,
      costs: rawCosts is List
          ? rawCosts
                .whereType<Map<String, dynamic>>()
                .map(UsageCost.fromJson)
                .toList()
          : const [],
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! UsageTotals) return false;
    if (other.costs.length != costs.length) return false;
    for (var i = 0; i < costs.length; i++) {
      if (costs[i] != other.costs[i]) return false;
    }
    return records == other.records &&
        inputTokens == other.inputTokens &&
        outputTokens == other.outputTokens &&
        thoughtTokens == other.thoughtTokens &&
        cachedReadTokens == other.cachedReadTokens &&
        cachedWriteTokens == other.cachedWriteTokens &&
        totalTokens == other.totalTokens;
  }

  @override
  int get hashCode => Object.hash(
    records,
    inputTokens,
    outputTokens,
    thoughtTokens,
    cachedReadTokens,
    cachedWriteTokens,
    totalTokens,
    Object.hashAll(costs),
  );
}

/// Zero totals, used when the response carries no `usage` object.
const emptyUsageTotals = UsageTotals(
  records: 0,
  inputTokens: 0,
  outputTokens: 0,
  thoughtTokens: 0,
  cachedReadTokens: 0,
  cachedWriteTokens: 0,
  totalTokens: 0,
  costs: [],
);

/// Response of `GET /api/usage`.
class UsageSummary {
  final String sinceDay;
  final String untilDay;
  final List<UsageBucket> buckets;
  final UsageTotals totals;

  const UsageSummary({
    required this.sinceDay,
    required this.untilDay,
    required this.buckets,
    required this.totals,
  });

  factory UsageSummary.fromJson(Map<String, dynamic> j) {
    final rawBuckets = j['buckets'];
    final rawTotals = j['totals'];
    return UsageSummary(
      sinceDay: j['since_day'] as String? ?? '',
      untilDay: j['until_day'] as String? ?? '',
      buckets: rawBuckets is List
          ? rawBuckets
                .whereType<Map<String, dynamic>>()
                .map(UsageBucket.fromJson)
                .toList()
          : const [],
      totals: rawTotals is Map<String, dynamic>
          ? UsageTotals.fromJson(rawTotals)
          : const UsageTotals(
              records: 0,
              inputTokens: 0,
              outputTokens: 0,
              thoughtTokens: 0,
              cachedReadTokens: 0,
              cachedWriteTokens: 0,
              totalTokens: 0,
              costs: [],
            ),
    );
  }
}

/// Response of `GET /api/threads/:id/context`: the thread's recorded token
/// totals plus whether a live provider session exists.
class ThreadContextUsage {
  /// Whether a provider session exists, i.e. whether resetting the context
  /// would drop anything.
  final bool hasSession;

  /// Recorded token usage for this thread across all turns.
  final UsageTotals usage;

  const ThreadContextUsage({
    this.hasSession = false,
    this.usage = emptyUsageTotals,
  });

  factory ThreadContextUsage.fromJson(Map<String, dynamic> j) =>
      ThreadContextUsage(
        hasSession: j['has_session'] as bool? ?? false,
        usage: j['usage'] is Map<String, dynamic>
            ? UsageTotals.fromJson(j['usage'] as Map<String, dynamic>)
            : emptyUsageTotals,
      );

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! ThreadContextUsage) return false;
    return hasSession == other.hasSession && usage == other.usage;
  }

  @override
  int get hashCode => Object.hash(hasSession, usage);
}

/// Compacts a token count to three significant figures with a unit suffix
/// (`1.5K`, `23.4M`, `2.01B`).
String formatTokens(int value) {
  final abs = value.abs();
  String trim(double v) {
    final digits = v.abs() >= 100 ? 0 : (v.abs() >= 10 ? 1 : 2);
    var s = v.toStringAsFixed(digits);
    if (s.contains('.')) {
      s = s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
    }
    return s;
  }

  if (abs >= 1e12) return '${trim(value / 1e12)}T';
  if (abs >= 1e9) return '${trim(value / 1e9)}B';
  if (abs >= 1e6) return '${trim(value / 1e6)}M';
  if (abs >= 1e3) return '${trim(value / 1e3)}K';
  return '$value';
}
