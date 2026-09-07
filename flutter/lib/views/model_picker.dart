import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../models/models.dart';
import '../theme/semantic_colors.dart';

/// A Devin-style model picker: a search-able, two-pane popup that shows
/// model families on the left and the selected/hovered model's details on
/// the right.
class ModelPicker extends StatelessWidget {
  final String value;
  final List<ModelInfo> models;
  final ValueChanged<String> onChanged;
  final bool enabled;
  final bool compact;

  const ModelPicker({
    super.key,
    required this.value,
    required this.models,
    required this.onChanged,
    this.enabled = true,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selected = _findSelected(models, value, l10n(context));
    final disabledColor = theme.colorScheme.onSurface.withValues(alpha: 0.38);
    final contentColor = enabled ? theme.colorScheme.onSurface : disabledColor;

    final label = compact ? _shortLabel(selected) : _triggerLabel(selected);

    return InkWell(
      onTap: enabled ? () => _showPicker(context) : null,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(20),
        ),
        padding: compact
            ? const EdgeInsets.symmetric(horizontal: 8, vertical: 4)
            : const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _CostDot(
              tier: selected.costTier,
              color: enabled ? null : disabledColor,
            ),
            const SizedBox(width: 8),
            Text(
              label,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: contentColor,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(width: 4),
            Icon(
              Icons.expand_more,
              size: 16,
              color: enabled
                  ? theme.colorScheme.onSurfaceVariant
                  : disabledColor,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showPicker(BuildContext context) {
    return showDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.5),
      builder: (context) => _ModelPickerDialog(
        value: value,
        models: models,
        onChanged: onChanged,
      ),
    );
  }
}

class _ModelPickerDialog extends StatefulWidget {
  final String value;
  final List<ModelInfo> models;
  final ValueChanged<String> onChanged;

  const _ModelPickerDialog({
    required this.value,
    required this.models,
    required this.onChanged,
  });

  @override
  State<_ModelPickerDialog> createState() => _ModelPickerDialogState();
}

class _ModelPickerDialogState extends State<_ModelPickerDialog> {
  String _search = '';
  String? _hoveredId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final media = MediaQuery.of(context);
    final isNarrow = media.size.width < 640;
    final l = l10n(context);
    final filtered = _filter(widget.models, _search);
    final grouped = _groupModels(filtered, l);
    final selectedId = _hoveredId ?? widget.value;
    final selected = _findSelected(widget.models, selectedId, l);

    final modelList = _ModelList(
      grouped: grouped,
      value: widget.value,
      hoveredId: _hoveredId,
      onHover: (id) => setState(() => _hoveredId = id),
      onSelect: (id) {
        widget.onChanged(id);
        Navigator.of(context).pop();
      },
    );

    final modelDetails = _ModelDetails(
      model: selected,
      isSelected: selected.id == widget.value,
      onSelect: selected.id.isEmpty
          ? null
          : () {
              widget.onChanged(selected.id);
              Navigator.of(context).pop();
            },
    );

    final panes = isNarrow
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: modelList),
              const SizedBox(height: 8),
              SizedBox(height: 180, child: modelDetails),
            ],
          )
        : Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 3, child: modelList),
              VerticalDivider(
                color: theme.colorScheme.outline.withValues(alpha: 0.25),
                width: 16,
              ),
              Expanded(flex: 2, child: modelDetails),
            ],
          );

    return Dialog(
      backgroundColor: theme.colorScheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        width: isNarrow ? media.size.width * 0.95 : 760,
        height: isNarrow ? media.size.height * 0.85 : 520,
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            _SearchField(
              value: _search,
              onChanged: (v) => setState(() => _search = v),
            ),
            const SizedBox(height: 12),
            Expanded(child: panes),
          ],
        ),
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;
  const _SearchField({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return TextField(
      onChanged: onChanged,
      decoration: InputDecoration(
        hintText: l10n(context).searchModels,
        prefixIcon: Icon(
          Icons.search,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        filled: true,
        fillColor: theme.colorScheme.surfaceContainer,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(vertical: 12),
      ),
    );
  }
}

class _ModelList extends StatelessWidget {
  final Map<String, Map<String, List<ModelInfo>>> grouped;
  final String value;
  final String? hoveredId;
  final ValueChanged<String> onHover;
  final ValueChanged<String> onSelect;

  const _ModelList({
    required this.grouped,
    required this.value,
    required this.hoveredId,
    required this.onHover,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bases = grouped.keys.toList()..sort();

    if (bases.isEmpty) {
      return Center(
        child: Text(
          l10n(context).noModelsMatch,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return ListView.builder(
      itemCount: bases.length,
      itemBuilder: (context, index) {
        final base = bases[index];
        final subs = grouped[base]!;
        return _FamilyGroup(
          base: base,
          subs: subs,
          value: value,
          hoveredId: hoveredId,
          onHover: onHover,
          onSelect: onSelect,
        );
      },
    );
  }
}

class _FamilyGroup extends StatelessWidget {
  final String base;
  final Map<String, List<ModelInfo>> subs;
  final String value;
  final String? hoveredId;
  final ValueChanged<String> onHover;
  final ValueChanged<String> onSelect;

  const _FamilyGroup({
    required this.base,
    required this.subs,
    required this.value,
    required this.hoveredId,
    required this.onHover,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final subKeys = subs.keys.toList()..sort();
    final hasSubs = subKeys.any((k) => k.isNotEmpty);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
            child: Text(
              base,
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.onSurface,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          for (final sub in subKeys)
            if (sub.isNotEmpty && hasSubs)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: 4,
                        horizontal: 12,
                      ),
                      child: Text(
                        sub,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    for (final m in subs[sub]!)
                      _ModelRow(
                        model: m,
                        isSelected: m.id == value,
                        isActive: m.id == value || m.id == hoveredId,
                        onHover: () => onHover(m.id),
                        onSelect: () => onSelect(m.id),
                      ),
                  ],
                ),
              )
            else
              for (final m in subs[sub]!)
                _ModelRow(
                  model: m,
                  isSelected: m.id == value,
                  isActive: m.id == value || m.id == hoveredId,
                  onHover: () => onHover(m.id),
                  onSelect: () => onSelect(m.id),
                ),
        ],
      ),
    );
  }
}

class _ModelRow extends StatelessWidget {
  final ModelInfo model;
  final bool isSelected;
  final bool isActive;
  final VoidCallback onHover;
  final VoidCallback onSelect;

  const _ModelRow({
    required this.model,
    required this.isSelected,
    required this.isActive,
    required this.onHover,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = l10n(context);
    final isFree = _isFree(model);
    final contextText = l.contextWithTokens(
      _formatTokens(model.maxContextTokens, l),
    );

    return InkWell(
      onTap: onSelect,
      onHover: (h) {
        if (h) onHover();
      },
      onFocusChange: (f) {
        if (f) onHover();
      },
      borderRadius: BorderRadius.circular(8),
      child: Container(
        decoration: BoxDecoration(
          color: isActive
              ? theme.colorScheme.primaryContainer.withValues(alpha: 0.5)
              : null,
          borderRadius: BorderRadius.circular(8),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            _CostDot(tier: model.costTier),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _shortLabel(model),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: isActive
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurface,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      if (isFree)
                        _Badge(
                          text: l10n(context).free,
                          color: theme.colorScheme.tertiary,
                        )
                      else if (_isPromo(model))
                        _Badge(
                          text: l10n(context).promo,
                          color: theme.colorScheme.primary,
                        )
                      else
                        _CostBar(tier: model.costTier),
                      const SizedBox(width: 8),
                      Text(
                        contextText,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      if (model.isNew) ...[
                        const SizedBox(width: 6),
                        _Badge(
                          text: l10n(context).newLabel,
                          color: theme.colorScheme.primary,
                        ),
                      ],
                      if (model.isBeta) ...[
                        const SizedBox(width: 6),
                        _Badge(
                          text: l10n(context).beta,
                          color: theme.colorScheme.error,
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            if (isSelected)
              Icon(Icons.check, size: 18, color: theme.colorScheme.primary),
          ],
        ),
      ),
    );
  }
}

class _ModelDetails extends StatelessWidget {
  final ModelInfo model;
  final bool isSelected;
  final VoidCallback? onSelect;

  const _ModelDetails({
    required this.model,
    required this.isSelected,
    this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = l10n(context);

    if (model.id.isEmpty) {
      return Center(
        child: Text(
          l10n(context).noModelSelected,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _triggerLabel(model),
            style: theme.textTheme.titleMedium?.copyWith(
              color: theme.colorScheme.onSurface,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
          _DetailRow(
            label: l.modelContextLabel,
            value: _formatTokens(model.maxContextTokens, l),
          ),
          _DetailRow(
            label: l.modelOutputLabel,
            value: _formatTokens(model.maxOutputTokens, l),
          ),
          _DetailRow(
            label: l.costTierLabel,
            value: model.costTier.isEmpty ? l.noValue : model.costTier,
          ),
          if (model.costSummary.isNotEmpty)
            _DetailRow(label: l.pricingLabel, value: model.costSummary),
          const SizedBox(height: 16),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              if (_isFree(model))
                _Badge(text: l.free, color: theme.colorScheme.tertiary),
              if (_isPromo(model))
                _Badge(text: l.promo, color: theme.colorScheme.primary),
              if (model.isNew)
                _Badge(text: l.newLabel, color: theme.colorScheme.primary),
              if (model.isBeta)
                _Badge(text: l.beta, color: theme.colorScheme.error),
            ],
          ),
          const SizedBox(height: 24),
          if (onSelect != null)
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: onSelect,
                child: Text(isSelected ? l.selected : l.selectModel),
              ),
            ),
        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;
  const _DetailRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  final String text;
  final Color color;
  const _Badge({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _CostDot extends StatelessWidget {
  final String tier;
  final Color? color;
  const _CostDot({required this.tier, this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        color: color ?? _tierColor(tier, Theme.of(context)),
        shape: BoxShape.circle,
      ),
    );
  }
}

class _CostBar extends StatelessWidget {
  final String tier;
  const _CostBar({required this.tier});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = _tierColor(tier, theme);
    final width = _tierBarWidth(tier);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 40,
          height: 4,
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(2),
          ),
          child: FractionallySizedBox(
            alignment: Alignment.centerLeft,
            widthFactor: width,
            child: Container(
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
        const SizedBox(width: 4),
        Text(
          tier,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

final _versionSuffix = RegExp(r'\d+(?:\.\d+)?$');

String _triggerLabel(ModelInfo m) {
  final f = m.family.trim();
  final l = m.label.trim();
  if (f.isNotEmpty && !l.toLowerCase().startsWith(f.toLowerCase())) {
    return '$f $l';
  }
  return l;
}

String _shortLabel(ModelInfo m) {
  final f = m.family.trim().toLowerCase();
  final l = m.label.trim();
  if (f.isEmpty) return l;
  if (l.toLowerCase().startsWith(f)) {
    var rest = l.substring(f.length).trim();
    rest = rest.replaceFirst(RegExp(r'^[-_\s]+'), '');
    return rest.isEmpty ? l : rest;
  }
  return l;
}

bool _isFree(ModelInfo m) {
  return m.costTier.toLowerCase().contains('free') ||
      m.costSummary.toLowerCase().contains('free');
}

bool _isPromo(ModelInfo m) {
  return m.costTier.toLowerCase().contains('promo') ||
      m.costSummary.toLowerCase().contains('promo');
}

String _formatTokens(int tokens, AppLocalizations l) {
  if (tokens <= 0) return l.noValue;
  if (tokens >= 1_000_000) {
    final count = (tokens / 1_000_000).toStringAsFixed(
      tokens % 1_000_000 == 0 ? 0 : 1,
    );
    return l.tokensMillionSuffix(count);
  }
  if (tokens >= 1_000) {
    final count = (tokens / 1_000).toStringAsFixed(tokens % 1_000 == 0 ? 0 : 1);
    return l.tokensThousandSuffix(count);
  }
  return l.tokensCount('$tokens');
}

Color _tierColor(String tier, ThemeData theme) {
  final scheme = theme.colorScheme;
  final semantic =
      theme.extension<SemanticColors>() ??
      SemanticColors.fallback(theme.brightness);
  final lower = tier.toLowerCase();
  if (lower.contains('free')) return scheme.tertiary;
  if (lower.contains('low')) return semantic.success;
  if (lower.contains('medium')) return semantic.warning;
  if (lower.contains('high')) return scheme.error;
  return scheme.primary;
}

double _tierBarWidth(String tier) {
  final lower = tier.toLowerCase();
  if (lower.contains('free')) return 0.0;
  if (lower.contains('low')) return 0.25;
  if (lower.contains('medium')) return 0.55;
  if (lower.contains('high')) return 1.0;
  return 0.4;
}

({String base, String sub}) _splitFamily(String family, AppLocalizations l) {
  final f = family.trim();
  if (f.isEmpty) return (base: l.otherFamily, sub: '');

  String trySplit(String sep) {
    final parts = f.split(sep);
    if (parts.length < 2) return '';
    final last = parts.last.trim();
    final prefix = parts.sublist(0, parts.length - 1).join(sep).trim();
    if (!_versionSuffix.hasMatch(last) && _versionSuffix.hasMatch(prefix)) {
      return last;
    }
    return '';
  }

  final spaceSub = trySplit(' ');
  if (spaceSub.isNotEmpty) {
    final base = f.substring(0, f.length - spaceSub.length).trim();
    return (base: base, sub: spaceSub);
  }

  final dashSub = trySplit('-');
  if (dashSub.isNotEmpty) {
    final base = f.substring(0, f.length - dashSub.length).trim();
    return (base: base, sub: dashSub);
  }

  final parts = f.split(' ');
  if (parts.length >= 3 && _versionSuffix.hasMatch(parts.last)) {
    final base = '${parts.first} ${parts.last}';
    final sub = parts.sublist(1, parts.length - 1).join(' ');
    return (base: base, sub: sub);
  }

  return (base: f, sub: '');
}

Map<String, Map<String, List<ModelInfo>>> _groupModels(
  List<ModelInfo> models,
  AppLocalizations l,
) {
  final groups = <String, Map<String, List<ModelInfo>>>{};
  for (final m in models) {
    final split = _splitFamily(m.family, l);
    groups
        .putIfAbsent(split.base, () => {})
        .putIfAbsent(split.sub, () => [])
        .add(m);
  }
  for (final subs in groups.values) {
    for (final list in subs.values) {
      list.sort((a, b) => a.label.compareTo(b.label));
    }
  }
  return groups;
}

List<ModelInfo> _filter(List<ModelInfo> models, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return models;
  return models.where((m) {
    return m.label.toLowerCase().contains(q) ||
        m.family.toLowerCase().contains(q) ||
        m.costTier.toLowerCase().contains(q);
  }).toList();
}

ModelInfo _findSelected(
  List<ModelInfo> models,
  String value,
  AppLocalizations l,
) {
  if (models.isEmpty) {
    return ModelInfo(id: '', label: l.model, costTier: '', family: '');
  }
  return models.firstWhere(
    (m) => m.id == value,
    orElse: () => value.isNotEmpty
        ? ModelInfo(id: value, label: value, costTier: '', family: '')
        : ModelInfo(id: '', label: l.model, costTier: '', family: ''),
  );
}
