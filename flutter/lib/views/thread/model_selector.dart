part of '../thread_page.dart';

typedef _ModelSelectorData = ({
  List<ProviderInfo> providers,
  List<ModelInfo> models,
  String selectedProvider,
  String selectedModel,
});

/// Combined provider + model picker. The trigger shows the provider icon and
/// the selected model; the dialog lists providers on the left and the current
/// provider's models on the right.
class _ModelSelector extends StatelessWidget {
  final bool enabled;
  final bool providerLocked;
  final bool compact;

  const _ModelSelector({
    this.enabled = true,
    this.providerLocked = false,
    this.compact = false,
  });

  ModelInfo? _findModel(List<ModelInfo> models, String id) {
    for (final m in models) {
      if (m.id == id) return m;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final appL10n = l10n(context);
    return Selector<AppState, _ModelSelectorData>(
      selector: (_, s) => (
        providers: s.providers,
        models: s.models,
        selectedProvider: s.selectedProvider,
        selectedModel: s.selectedModel,
      ),
      builder: (context, data, _) {
        final model = _findModel(data.models, data.selectedModel);
        final label = model != null
            ? (compact ? _shortModelLabel(model) : _triggerLabel(model))
            : (data.selectedModel.isNotEmpty
                  ? data.selectedModel
                  : appL10n.noModelSelected);
        return Opacity(
          opacity: enabled ? 1.0 : 0.5,
          child: InkWell(
            key: const Key('model_selector'),
            borderRadius: BorderRadius.circular(6),
            onTap: enabled
                ? () {
                    final state = context.read<AppState>();
                    showDialog(
                      context: context,
                      builder: (_) => ChangeNotifierProvider<AppState>.value(
                        value: state,
                        child: _ModelSelectorDialog(
                          providerLocked: providerLocked,
                        ),
                      ),
                    );
                  }
                : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ProviderIcon(
                    providerId: data.selectedProvider,
                    size: 15,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      label,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Icon(
                    Icons.expand_more,
                    size: 16,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ModelSelectorDialog extends StatefulWidget {
  final bool providerLocked;

  const _ModelSelectorDialog({required this.providerLocked});

  @override
  State<_ModelSelectorDialog> createState() => _ModelSelectorDialogState();
}

class _ModelSelectorDialogState extends State<_ModelSelectorDialog> {
  final TextEditingController _search = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    // Loading the catalog can notify listeners; defer past the first frame so
    // the dialog does not rebuild mid-mount.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final state = context.read<AppState>();
      unawaited(state.ensureModelsFor(state.selectedProvider));
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _selectModel(AppState state, ModelInfo model) {
    state.setSelectedModel(model.id);
    unawaited(state.saveThreadSettings());
    Navigator.of(context).pop();
  }

  void _selectProvider(AppState state, ProviderInfo provider) {
    if (widget.providerLocked) return;
    unawaited(state.setSelectedProvider(provider.id));
    unawaited(state.saveThreadSettings());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final appL10n = l10n(context);
    final state = context.watch<AppState>();
    final providers = state.providers;
    final models = state.models;
    final selectedProvider = state.selectedProvider;
    final selectedModel = state.selectedModel;
    ProviderInfo? provider;
    for (final p in providers) {
      if (p.id == selectedProvider) {
        provider = p;
        break;
      }
    }
    final filtered = _query.isEmpty
        ? models
        : models
              .where(
                (m) =>
                    m.label.toLowerCase().contains(_query) ||
                    m.family.toLowerCase().contains(_query) ||
                    m.id.toLowerCase().contains(_query),
              )
              .toList();

    return Dialog(
      backgroundColor: theme.colorScheme.surface,
      insetPadding: const EdgeInsets.symmetric(horizontal: 32, vertical: 48),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: SizedBox(
        width: 720,
        height: 520,
        child: Row(
          children: [
            if (providers.length > 1)
              Container(
                width: 64,
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerLow,
                  borderRadius: const BorderRadius.horizontal(
                    left: Radius.circular(12),
                  ),
                ),
                child: ListView(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  children: [
                    for (final p in providers)
                      _ProviderRailItem(
                        provider: p,
                        selected: p.id == selectedProvider,
                        enabled: !widget.providerLocked,
                        onTap: () => _selectProvider(state, p),
                      ),
                  ],
                ),
              ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                    child: TextField(
                      controller: _search,
                      autofocus: false,
                      decoration: InputDecoration(
                        hintText: appL10n.searchModels,
                        isDense: true,
                        prefixIcon: const Icon(Icons.search, size: 18),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      onChanged: (v) =>
                          setState(() => _query = v.trim().toLowerCase()),
                    ),
                  ),
                  Expanded(
                    child: filtered.isEmpty
                        ? Center(child: Text(appL10n.noModelsMatch))
                        : ListView.builder(
                            padding: const EdgeInsets.only(bottom: 12),
                            itemCount: filtered.length,
                            itemBuilder: (context, i) {
                              final m = filtered[i];
                              final selected = m.id == selectedModel;
                              return _ModelRow(
                                model: m,
                                providerName: provider?.name ?? '',
                                selected: selected,
                                onTap: () => _selectModel(state, m),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProviderRailItem extends StatelessWidget {
  final ProviderInfo provider;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  const _ProviderRailItem({
    required this.provider,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: Tooltip(
        message: provider.name,
        child: Material(
          color: selected
              ? theme.colorScheme.primaryContainer
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: enabled ? onTap : null,
            child: Opacity(
              opacity: enabled ? 1.0 : 0.5,
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: ProviderIcon(
                  providerId: provider.id,
                  size: 20,
                  color: selected
                      ? theme.colorScheme.onPrimaryContainer
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ModelRow extends StatelessWidget {
  final ModelInfo model;
  final String providerName;
  final bool selected;
  final VoidCallback onTap;

  const _ModelRow({
    required this.model,
    required this.providerName,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final appL10n = l10n(context);
    final isFree = model.isFree;
    final isPromo = model.isPromo;
    final pricing = model.costSummary.trim();
    final subtitle = [
      if (providerName.isNotEmpty) providerName,
      if (pricing.isNotEmpty) pricing,
    ].join(' · ');
    return ListTile(
      dense: true,
      selected: selected,
      selectedTileColor: theme.colorScheme.primaryContainer.withAlpha(40),
      title: Row(
        children: [
          Flexible(
            child: Text(
              model.label.isNotEmpty ? model.label : model.id,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (isFree || isPromo) ...[
            const SizedBox(width: 6),
            Tooltip(
              message: isFree ? appL10n.free : appL10n.promo,
              child: Icon(
                Icons.card_giftcard,
                size: 14,
                color: isFree
                    ? theme.colorScheme.tertiary
                    : theme.colorScheme.primary,
              ),
            ),
          ],
        ],
      ),
      subtitle: subtitle.isEmpty
          ? null
          : Text(
              subtitle,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              overflow: TextOverflow.ellipsis,
            ),
      trailing: selected
          ? Icon(Icons.check, size: 16, color: theme.colorScheme.primary)
          : null,
      onTap: onTap,
    );
  }
}

String _triggerLabel(ModelInfo m) {
  final family = m.family.trim();
  final label = m.label.trim();
  if (family.isNotEmpty &&
      !label.toLowerCase().startsWith(family.toLowerCase())) {
    return '$family $label';
  }
  return label;
}

String _shortModelLabel(ModelInfo m) {
  final family = m.family.trim().toLowerCase();
  final label = m.label.trim();
  if (family.isEmpty) return label;
  if (label.toLowerCase().startsWith(family)) {
    var rest = label.substring(family.length).trim();
    rest = rest.replaceFirst(RegExp(r'^[-_\s]+'), '');
    return rest.isEmpty ? label : rest;
  }
  return label;
}
