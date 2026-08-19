import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import '../models/models.dart';
import '../state/app_state.dart';

/// An inline ask form that lives in the chat prompt area instead of a modal.
///
/// Renders each [AskQuestion] as a field, validates the form, and forwards the
/// answers to [AppState.respondToAskRequest].
class AskRequestPanel extends StatefulWidget {
  const AskRequestPanel({super.key});

  @override
  State<AskRequestPanel> createState() => _AskRequestPanelState();
}

class _AskRequestPanelState extends State<AskRequestPanel> {
  final _formKey = GlobalKey<FormState>();
  final _answers = <String, dynamic>{};

  void _submit() {
    if (_formKey.currentState?.validate() ?? false) {
      _formKey.currentState?.save();
      final answers = Map<String, dynamic>.from(_answers)
        ..removeWhere(
          (k, v) => v == null || (v is List && v.isEmpty),
        );
      context.read<AppState>().respondToAskRequest(answers);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final req = state.pendingAskRequest;
    if (req == null || req.questions.isEmpty) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final media = MediaQuery.of(context);
    final l = l10n(context);

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
        child: Material(
          color: theme.colorScheme.surfaceContainer,
          elevation: 1,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(28),
            side: BorderSide(
              color: theme.colorScheme.primary.withAlpha(120),
            ),
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: media.size.height * 0.7,
            ),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildHeader(context, req, theme),
                    const SizedBox(height: 16),
                    Flexible(
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (var i = 0; i < req.questions.length; i++) ...[
                              _buildField(
                                context,
                                req.questions[i],
                                isFirst: i == 0,
                              ),
                              if (i < req.questions.length - 1)
                                const SizedBox(height: 16),
                            ],
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () => state.respondToAskRequest(null),
                          child: Text(l.cancel),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: _submit,
                          child: Text(l.send),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, AskRequest req, ThemeData theme) {
    final title =
        req.message.isNotEmpty ? req.message : l10n(context).askRequest;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          Icons.help_outline,
          color: theme.colorScheme.primary,
          size: 20,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildField(BuildContext context, AskQuestion q, {bool isFirst = false}) {
    final theme = Theme.of(context);
    final label = q.prompt;
    final hint = q.description;

    if (q.isText) {
      return TextFormField(
        autofocus: isFirst,
        textInputAction: TextInputAction.done,
        onFieldSubmitted: (_) => _submit(),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          border: const OutlineInputBorder(),
        ),
        validator: (v) {
          if (v == null || v.trim().isEmpty) {
            return q.required ? l10n(context).required : null;
          }
          return null;
        },
        onSaved: (v) => _answers[q.id] = v?.trim(),
      );
    }

    if (q.isNumber) {
      return TextFormField(
        autofocus: isFirst,
        textInputAction: TextInputAction.done,
        onFieldSubmitted: (_) => _submit(),
        keyboardType:
            const TextInputType.numberWithOptions(decimal: true, signed: true),
        inputFormatters: [
          FilteringTextInputFormatter.allow(RegExp(r'^-?\d*\.?\d*$')),
        ],
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          border: const OutlineInputBorder(),
        ),
        validator: (v) {
          if (v == null || v.trim().isEmpty) {
            return q.required ? l10n(context).required : null;
          }
          if (num.tryParse(v.trim()) == null) {
            return l10n(context).invalidNumber;
          }
          return null;
        },
        onSaved: (v) {
          if (v == null) return;
          final trimmed = v.trim();
          if (trimmed.isEmpty) return;
          _answers[q.id] = num.tryParse(trimmed);
        },
      );
    }

    if (q.isBoolean) {
      return FormField<bool>(
        initialValue: false,
        builder: (field) => SwitchListTile(
          title: Text(label),
          subtitle: hint != null ? Text(hint) : null,
          value: field.value ?? false,
          onChanged: (v) {
            field.didChange(v);
            _answers[q.id] = v;
          },
        ),
        onSaved: (v) => _answers[q.id] = v ?? false,
      );
    }

    if (q.isSingleSelect) {
      return FormField<String>(
        builder: (field) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: theme.textTheme.titleSmall),
            if (hint != null) ...[
              const SizedBox(height: 4),
              Text(hint, style: theme.textTheme.bodySmall),
            ],
            const SizedBox(height: 8),
            for (var i = 0; i < q.options.length; i++)
              _OptionTile(
                index: i + 1,
                label: q.options[i].label,
                selected: field.value == q.options[i].value,
                onTap: () {
                  final value = q.options[i].value;
                  field.didChange(value);
                  _answers[q.id] = value;
                },
              ),
            if (field.hasError)
              Text(
                field.errorText!,
                style: TextStyle(color: theme.colorScheme.error),
              ),
          ],
        ),
        validator: q.required
            ? (v) => v == null ? l10n(context).required : null
            : null,
        onSaved: (v) => _answers[q.id] = v,
      );
    }

    if (q.isMultiSelect) {
      return FormField<Set<String>>(
        initialValue: const <String>{},
        builder: (field) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: theme.textTheme.titleSmall),
            if (hint != null) ...[
              const SizedBox(height: 4),
              Text(hint, style: theme.textTheme.bodySmall),
            ],
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: q.options.map((o) {
                final selected = field.value?.contains(o.value) ?? false;
                return FilterChip(
                  label: Text(o.label),
                  selected: selected,
                  onSelected: (sel) {
                    final next =
                        Set<String>.of(field.value ?? const <String>{});
                    if (sel) {
                      next.add(o.value);
                    } else {
                      next.remove(o.value);
                    }
                    field.didChange(next);
                    _answers[q.id] = next.toList();
                  },
                );
              }).toList(),
            ),
            if (field.hasError)
              Text(
                field.errorText!,
                style: TextStyle(color: theme.colorScheme.error),
              ),
          ],
        ),
        validator: q.required
            ? (v) => (v == null || v.isEmpty) ? l10n(context).required : null
            : null,
        onSaved: (v) => _answers[q.id] = (v ?? const <String>{}).toList(),
      );
    }

    return TextFormField(
      autofocus: isFirst,
      textInputAction: TextInputAction.done,
      onFieldSubmitted: (_) => _submit(),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        border: const OutlineInputBorder(),
      ),
      onSaved: (v) => _answers[q.id] = v?.trim(),
    );
  }
}

class _OptionTile extends StatelessWidget {
  final int index;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _OptionTile({
    required this.index,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: selected
            ? theme.colorScheme.primaryContainer
            : theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              border: Border.all(
                color: selected
                    ? theme.colorScheme.primary
                    : theme.colorScheme.outlineVariant,
              ),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                _IndexBadge(index: index, selected: selected),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: selected
                          ? theme.colorScheme.onPrimaryContainer
                          : theme.colorScheme.onSurface,
                      fontWeight:
                          selected ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                ),
                if (selected)
                  Icon(
                    Icons.check,
                    color: theme.colorScheme.primary,
                    size: 18,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _IndexBadge extends StatelessWidget {
  final int index;
  final bool selected;

  const _IndexBadge({required this.index, required this.selected});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      width: 28,
      height: 28,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: selected
            ? theme.colorScheme.primary
            : theme.colorScheme.surfaceContainer,
        border: Border.all(
          color: selected
              ? theme.colorScheme.primary
              : theme.colorScheme.outlineVariant,
        ),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Text(
        '$index',
        style: TextStyle(
          color: selected
              ? theme.colorScheme.onPrimary
              : theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
          fontSize: 12,
        ),
      ),
    );
  }
}
