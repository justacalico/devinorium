part of '../thread_page.dart';

/// Reasoning-effort picker for the current model. The levels come from the
/// provider's model catalog; when a model advertises none the control hides.
class _ReasoningDropdown extends StatelessWidget {
  final List<ModelInfo> models;
  final String selectedModel;
  final String value;
  final ValueChanged<String> onChanged;
  final bool enabled;
  final bool compact;

  const _ReasoningDropdown({
    required this.models,
    required this.selectedModel,
    required this.value,
    required this.onChanged,
    this.enabled = true,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final appL10n = l10n(context);

    ModelInfo? model;
    for (final m in models) {
      if (m.id == selectedModel) {
        model = m;
        break;
      }
    }
    final supported = reasoningEffortsFor(model);
    if (supported.isEmpty) return const SizedBox.shrink();

    final defaultEffort = model?.defaultReasoningEffort ?? '';
    final effectiveValue = effectiveReasoningEffort(model, value);

    Widget chip() => Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withAlpha(30),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        appL10n.reasoningDefault,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );

    return Opacity(
      opacity: enabled ? 1.0 : 0.5,
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: effectiveValue,
          isDense: true,
          borderRadius: BorderRadius.circular(8),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w500,
          ),
          icon: Icon(
            Icons.expand_more,
            size: 16,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          onChanged: enabled ? (v) => onChanged(v ?? '') : null,
          items: [
            for (final e in supported)
              DropdownMenuItem(
                value: e,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(reasoningEffortLabel(e)),
                    if (e == defaultEffort) chip(),
                  ],
                ),
              ),
          ],
          selectedItemBuilder: (context) => [
            for (final e in supported)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(reasoningEffortLabel(e)),
                  if (e == defaultEffort) chip(),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
