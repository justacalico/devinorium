import 'provider.dart';

/// The reasoning levels a model advertises, in the provider's order.
List<String> reasoningEffortsFor(ModelInfo? model) =>
    model?.supportedReasoningEfforts ?? const [];

/// The value the picker should show: the user's selection when the model
/// supports it, else the provider default, else the first supported level.
String effectiveReasoningEffort(ModelInfo? model, String selected) {
  final supported = reasoningEffortsFor(model);
  if (supported.isEmpty) return '';
  if (supported.contains(selected)) return selected;
  final fallback = model?.defaultReasoningEffort ?? '';
  return supported.contains(fallback) ? fallback : supported.first;
}

/// Human-readable label for a provider-reported reasoning effort value.
///
/// The set of values comes from the provider's model catalog; this helper only
/// formats what the provider sends. Unknown values are title-cased so new
/// levels still render sensibly.
String reasoningEffortLabel(String effort) {
  switch (effort.toLowerCase()) {
    case 'none':
      return 'None';
    case 'minimal':
      return 'Minimal';
    case 'low':
      return 'Low';
    case 'medium':
      return 'Medium';
    case 'high':
      return 'High';
    case 'xhigh':
    case 'extra_high':
    case 'extra-high':
      return 'Extra High';
    case 'max':
      return 'Max';
    case 'ultra':
      return 'Ultra';
    case 'persistent':
      return 'Persistent';
    default:
      if (effort.isEmpty) return '';
      return effort[0].toUpperCase() + effort.substring(1);
  }
}
