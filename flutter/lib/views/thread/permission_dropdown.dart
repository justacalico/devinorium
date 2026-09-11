part of '../thread_page.dart';

class _PermissionDropdown extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;
  final bool enabled;
  final bool compact;
  const _PermissionDropdown({
    required this.value,
    required this.onChanged,
    this.enabled = true,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final l = l10n(context);
    final modes = permissionModeLabels(l);
    final fallback = !modes.any((m) => m.$1 == value)
        ? [DropdownMenuItem<String>(value: value, child: Text(value))]
        : <DropdownMenuItem<String>>[];
    final items = [
      for (final (id, label) in modes)
        DropdownMenuItem<String>(value: id, child: Text(label)),
      ...fallback,
    ];
    final effectiveValue = items.any((i) => i.value == value) ? value : null;

    return DropdownButton<String>(
      value: effectiveValue,
      underline: const SizedBox(),
      isDense: true,
      iconSize: 16,
      padding: compact ? const EdgeInsets.symmetric(horizontal: 4) : null,
      style: Theme.of(context).textTheme.bodyMedium,
      selectedItemBuilder: compact
          ? (_) => [
              for (final (_, label) in modes)
                Text(
                  _shortLabel(label),
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                ),
              for (final item in fallback)
                Text(
                  item.value!,
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
    );
  }

  static String _shortLabel(String label) {
    return label.split(RegExp(r'[\s-]')).first;
  }
}
