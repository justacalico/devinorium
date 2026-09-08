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
}

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
