part of '../thread_page.dart';

class _ProviderDropdown extends StatelessWidget {
  final String value;
  final List<ProviderInfo> providers;
  final ValueChanged<String> onChanged;
  final bool enabled;
  final bool compact;
  const _ProviderDropdown({
    required this.value,
    required this.providers,
    required this.onChanged,
    this.enabled = true,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    if (providers.isEmpty) return const SizedBox.shrink();
    final l = l10n(context);
    final items = [
      for (final p in providers)
        DropdownMenuItem<String>(value: p.id, child: Text(p.name)),
      // Keep the current selection visible even if the server no longer
      // lists it, so the dropdown never shows a bogus value.
      if (value.isNotEmpty && !providers.any((p) => p.id == value))
        DropdownMenuItem<String>(value: value, child: Text(value)),
    ];
    final effectiveValue = items.any((i) => i.value == value) ? value : null;

    return Tooltip(
      message: l.provider,
      child: DropdownButton<String>(
        value: effectiveValue,
        underline: const SizedBox(),
        isDense: true,
        iconSize: 16,
        padding: compact ? const EdgeInsets.symmetric(horizontal: 4) : null,
        style: Theme.of(context).textTheme.bodyMedium,
        selectedItemBuilder: compact
            ? (_) => [
                for (final item in items)
                  Text(
                    _shortLabel(item.child as Text),
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                  ),
              ]
            : null,
        items: items,
        onChanged: enabled
            ? (v) {
                if (v != null) onChanged(v);
              }
            : null,
      ),
    );
  }

  static String _shortLabel(Text label) {
    return label.data?.split(RegExp(r'[\s-]')).first ?? '';
  }
}
