class ProviderInfo {
  final String id;
  final String name;

  ProviderInfo({required this.id, required this.name});

  factory ProviderInfo.fromJson(Map<String, dynamic> j) => ProviderInfo(
    id: j['id'] as String,
    name: j['name'] as String? ?? j['id'] as String,
  );
}

class ModelInfo {
  final String id;
  final String label;
  final String costTier;
  final String family;
  final String costSummary;
  final int maxContextTokens;
  final int maxOutputTokens;
  final bool isNew;
  final bool isBeta;

  ModelInfo({
    required this.id,
    required this.label,
    required this.costTier,
    required this.family,
    this.costSummary = '',
    this.maxContextTokens = 0,
    this.maxOutputTokens = 0,
    this.isNew = false,
    this.isBeta = false,
  });

  factory ModelInfo.fromJson(Map<String, dynamic> j) => ModelInfo(
    id: j['id'] as String,
    label: j['label'] as String? ?? j['id'] as String,
    costTier: j['cost_tier'] as String? ?? '',
    family: j['family'] as String? ?? '',
    costSummary: j['cost_summary'] as String? ?? '',
    maxContextTokens: (j['max_context_tokens'] as num?)?.toInt() ?? 0,
    maxOutputTokens: (j['max_output_tokens'] as num?)?.toInt() ?? 0,
    isNew: j['is_new'] as bool? ?? false,
    isBeta: j['is_beta'] as bool? ?? false,
  );
}
