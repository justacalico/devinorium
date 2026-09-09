import 'auth.dart';

class ProviderInfo {
  final String id;
  final String name;

  ProviderInfo({required this.id, required this.name});

  factory ProviderInfo.fromJson(Map<String, dynamic> j) => ProviderInfo(
    id: j['id'] as String,
    name: j['name'] as String? ?? j['id'] as String,
  );
}

/// The command a provider defaults to when the user has not configured one.
/// Mirrors `providers::default_command` in the backend.
String defaultProviderCommand(String providerId) => switch (providerId) {
  'opencode' => 'opencode',
  'codex' => 'codex',
  _ => 'devin',
};

/// The effective command for a provider: the per-provider override first,
/// then the user's default-provider command, then the built-in default.
String providerCommandFor(User user, String providerId) {
  final override = user.providerCommands[providerId]?.trim() ?? '';
  if (override.isNotEmpty) return override;
  if (providerId == user.providerId && user.providerCommand.trim().isNotEmpty) {
    return user.providerCommand;
  }
  return defaultProviderCommand(providerId);
}

/// Installed and latest versions for the user's configured provider.
/// Either version is null when it could not be determined.
class ProviderVersion {
  final String providerId;
  final String providerName;
  final String? installedVersion;
  final String? latestVersion;
  final bool updateAvailable;

  const ProviderVersion({
    this.providerId = '',
    this.providerName = '',
    this.installedVersion,
    this.latestVersion,
    this.updateAvailable = false,
  });

  factory ProviderVersion.fromJson(Map<String, dynamic> j) => ProviderVersion(
    providerId: j['provider_id'] as String? ?? '',
    providerName: j['provider_name'] as String? ?? '',
    installedVersion: j['installed_version'] as String?,
    latestVersion: j['latest_version'] as String?,
    updateAvailable: j['update_available'] as bool? ?? false,
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
  final String defaultReasoningEffort;
  final List<String> supportedReasoningEfforts;

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
    this.defaultReasoningEffort = '',
    this.supportedReasoningEfforts = const [],
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
    defaultReasoningEffort: j['default_reasoning_effort'] as String? ?? '',
    supportedReasoningEfforts:
        (j['supported_reasoning_efforts'] as List<dynamic>?)
            ?.whereType<String>()
            .toList() ??
        const [],
  );
}
