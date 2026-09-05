import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import '../models/models.dart';
import '../state/app_state.dart';

/// An inline ask form that lives in the chat prompt area instead of a modal.
///
/// Shows one [AskQuestion] at a time with Previous / Next navigation and
/// forwards the collected answers to [AppState.respondToAskRequest].
class AskRequestPanel extends StatefulWidget {
  const AskRequestPanel({super.key});

  @override
  State<AskRequestPanel> createState() => _AskRequestPanelState();
}

const _otherValue = '__other__';

bool _isOtherValue(String value) => value == _otherValue || value == 'other';

class _AskRequestPanelState extends State<AskRequestPanel> {
  final _formKey = GlobalKey<FormState>();
  final _answers = <String, dynamic>{};
  final _textControllers = <String, TextEditingController>{};
  final _otherControllers = <String, TextEditingController>{};
  final _focusNodes = <String, FocusNode>{};
  final _otherFocusNodes = <String, FocusNode>{};
  int _currentIndex = 0;

  AskRequest? get _request => context.read<AppState>().pendingAskRequest;

  List<AskQuestion> get _questions => _request?.questions ?? const [];

  AskQuestion? get _currentQuestion {
    final questions = _questions;
    if (_currentIndex < 0 || _currentIndex >= questions.length) return null;
    return questions[_currentIndex];
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final req = _request;
    if (req == null) return;

    for (final q in req.questions) {
      if (q.isText || q.isNumber) {
        _textControllers.putIfAbsent(
          q.id,
          () => TextEditingController(text: _answers[q.id]?.toString() ?? ''),
        );
      }
      if (!q.isBoolean && !q.isSingleSelect && !q.isMultiSelect) {
        _focusNodes.putIfAbsent(q.id, () => FocusNode());
      }
      if (q.isSingleSelect) {
        _otherFocusNodes.putIfAbsent(q.id, () => FocusNode());
      }
    }
    _focusCurrent();
  }

  @override
  void dispose() {
    for (final c in _textControllers.values) {
      c.dispose();
    }
    for (final c in _otherControllers.values) {
      c.dispose();
    }
    for (final f in _focusNodes.values) {
      f.dispose();
    }
    for (final f in _otherFocusNodes.values) {
      f.dispose();
    }
    super.dispose();
  }

  void _focusCurrent() {
    final q = _currentQuestion;
    if (q == null) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (q.isText || q.isNumber) {
        _focusNodes[q.id]?.requestFocus();
      } else if (q.isSingleSelect) {
        final value = _answers[q.id] as String?;
        if (value != null && _isOtherValue(value)) {
          _otherFocusNodes[q.id]?.requestFocus();
        }
      }
    });
  }

  dynamic _currentValue(AskQuestion q) {
    if (q.isText || q.isNumber) {
      return _textControllers[q.id]?.text ?? '';
    }
    return _answers[q.id];
  }

  String? _validateAnswer(AskQuestion q, dynamic value, AppLocalizations l) {
    if (q.isText) {
      final text = (value as String?)?.trim() ?? '';
      if (q.required && text.isEmpty) return l.required;
      return null;
    }

    if (q.isNumber) {
      final text = (value as String?)?.trim() ?? '';
      if (text.isEmpty) {
        return q.required ? l.required : null;
      }
      if (num.tryParse(text) == null) return l.invalidNumber;
      return null;
    }

    if (q.isBoolean) return null;

    if (q.isSingleSelect) {
      if (value == null) return q.required ? l.required : null;
      if (value is String) {
        if (_isOtherValue(value)) {
          final text = _otherControllers[q.id]?.text.trim() ?? '';
          if (text.isEmpty && q.required) return l.required;
          return null;
        }
        if (value.trim().isEmpty && q.required) return l.required;
      }
      return null;
    }

    if (q.isMultiSelect) {
      final list = (value as List?)?.cast<String>();
      if (q.required && (list == null || list.isEmpty)) return l.required;
      return null;
    }

    return null;
  }

  Map<String, dynamic> _collectAnswers(AskRequest req) {
    final result = <String, dynamic>{};
    for (final q in req.questions) {
      final value = _currentValue(q);
      if (q.isText) {
        final text = (value as String?)?.trim() ?? '';
        if (text.isNotEmpty) result[q.id] = text;
      } else if (q.isNumber) {
        final text = (value as String?)?.trim() ?? '';
        if (text.isNotEmpty) {
          final n = num.tryParse(text);
          if (n != null) result[q.id] = n;
        }
      } else if (q.isBoolean) {
        result[q.id] = value ?? false;
      } else if (q.isSingleSelect) {
        final optionValues = q.options.map((o) => o.value).toSet();
        if (value is String && value.isNotEmpty) {
          if (_isOtherValue(value)) {
            final text = _otherControllers[q.id]?.text.trim() ?? '';
            if (text.isNotEmpty) result[q.id] = text;
          } else if (optionValues.contains(value)) {
            result[q.id] = value;
          } else {
            final text = value.trim();
            if (text.isNotEmpty) result[q.id] = text;
          }
        }
      } else if (q.isMultiSelect) {
        final list = (value as List?)?.cast<String>().toList() ?? const [];
        if (list.isNotEmpty) result[q.id] = list;
      }
    }
    return result;
  }

  void _previous() {
    if (_currentIndex <= 0) return;
    setState(() {
      _currentIndex--;
    });
    _focusCurrent();
  }

  void _nextOrSubmit() {
    if (_currentIndex >= _questions.length - 1) {
      _submit();
    } else {
      _next();
    }
  }

  void _next() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    _formKey.currentState?.save();
    setState(() {
      _currentIndex++;
    });
    _focusCurrent();
  }

  void _submit() {
    final req = _request;
    if (req == null) return;

    final l = l10n(context);
    for (var i = 0; i < req.questions.length; i++) {
      final q = req.questions[i];
      final error = _validateAnswer(q, _currentValue(q), l);
      if (error != null) {
        setState(() {
          _currentIndex = i;
        });
        _focusCurrent();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _formKey.currentState?.validate();
        });
        return;
      }
    }

    _formKey.currentState?.save();
    final answers = _collectAnswers(req);
    context.read<AppState>().respondToAskRequest(answers);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final media = MediaQuery.of(context);
    final l = l10n(context);
    final state = context.read<AppState>();

    return Selector<AppState, AskRequest?>(
      selector: (_, s) => s.pendingAskRequest,
      builder: (context, req, _) {
        if (req == null || req.questions.isEmpty) {
          return const SizedBox.shrink();
        }

        final question = _currentQuestion!;
        final isFirst = _currentIndex == 0;
        final isLast = _currentIndex == _questions.length - 1;

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
                    Text(
                      '${_currentIndex + 1} / ${_questions.length}',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Flexible(
                      child: SingleChildScrollView(
                        child: _buildField(context, question),
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
                        if (!isFirst) ...[
                          const SizedBox(width: 8),
                          TextButton(
                            onPressed: _previous,
                            child: Text(l.previous),
                          ),
                        ],
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: _nextOrSubmit,
                          child: Text(isLast ? l.send : l.next),
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
  });
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

  Widget _buildField(BuildContext context, AskQuestion q) {
    final theme = Theme.of(context);
    final label = q.prompt;
    final hint = q.description;
    final isLast = _currentIndex == _questions.length - 1;

    if (q.isText) {
      return TextFormField(
        focusNode: _focusNodes[q.id],
        controller: _textControllers[q.id],
        textInputAction: isLast ? TextInputAction.done : TextInputAction.next,
        onFieldSubmitted: (_) => _nextOrSubmit(),
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
        onSaved: (v) {
          final trimmed = v?.trim() ?? '';
          _answers[q.id] = trimmed.isNotEmpty ? trimmed : null;
          _textControllers[q.id]?.text = trimmed;
        },
      );
    }

    if (q.isNumber) {
      return TextFormField(
        focusNode: _focusNodes[q.id],
        controller: _textControllers[q.id],
        textInputAction: isLast ? TextInputAction.done : TextInputAction.next,
        onFieldSubmitted: (_) => _nextOrSubmit(),
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
          final parsed = num.tryParse(trimmed);
          _answers[q.id] = parsed;
          _textControllers[q.id]?.text = parsed?.toString() ?? '';
        },
      );
    }

    if (q.isBoolean) {
      return FormField<bool>(
        initialValue: _answers[q.id] as bool? ?? false,
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
      final options = q.options.toList();
      if (!options.any((o) => _isOtherValue(o.value))) {
        options.add(
          AskOption(value: _otherValue, label: l10n(context).otherOption),
        );
      }

      final currentValue = _answers[q.id] as String?;
      String? initialValue;
      if (currentValue != null) {
        final optionValues = options.map((o) => o.value).toSet();
        if (optionValues.contains(currentValue)) {
          initialValue = currentValue;
        } else {
          initialValue = _otherValue;
          _otherControllers.putIfAbsent(
            q.id,
            () => TextEditingController(text: currentValue),
          );
        }
      }

      return FormField<String>(
        initialValue: initialValue,
        builder: (field) {
          final selectedIsOther =
              field.value != null && _isOtherValue(field.value!);
          final otherController = selectedIsOther
              ? (_otherControllers[q.id] ??= TextEditingController())
              : null;

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: theme.textTheme.titleSmall),
              if (hint != null) ...[
                const SizedBox(height: 4),
                Text(hint, style: theme.textTheme.bodySmall),
              ],
              const SizedBox(height: 8),
              for (var i = 0; i < options.length; i++)
                _OptionTile(
                  index: i + 1,
                  label: options[i].label,
                  selected: field.value == options[i].value,
                  onTap: () {
                    final value = options[i].value;
                    field.didChange(value);
                    if (_isOtherValue(value)) {
                      _otherControllers[q.id] ??= TextEditingController();
                      _otherFocusNodes[q.id] ??= FocusNode();
                      _answers[q.id] = _otherControllers[q.id]?.text;
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (!mounted) return;
                        _otherFocusNodes[q.id]?.requestFocus();
                      });
                    } else {
                      _answers[q.id] = value;
                    }
                  },
                ),
              if (selectedIsOther) ...[
                const SizedBox(height: 12),
                TextFormField(
                  controller: otherController,
                  focusNode: _otherFocusNodes[q.id],
                  textInputAction:
                      isLast ? TextInputAction.done : TextInputAction.next,
                  onFieldSubmitted: (_) => _nextOrSubmit(),
                  onChanged: (v) => _answers[q.id] = v,
                  decoration: InputDecoration(
                    labelText: l10n(context).otherOption,
                    hintText: l10n(context).otherHint,
                    border: const OutlineInputBorder(),
                  ),
                  validator: (v) {
                    if (v == null || v.trim().isEmpty) {
                      return q.required ? l10n(context).required : null;
                    }
                    return null;
                  },
                ),
              ],
              if (field.hasError)
                Text(
                  field.errorText!,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
            ],
          );
        },
        validator: (v) {
          if (v == null) {
            return q.required ? l10n(context).required : null;
          }
          if (q.required && _isOtherValue(v)) {
            final text = _otherControllers[q.id]?.text.trim() ?? '';
            if (text.isEmpty) {
              return l10n(context).required;
            }
          }
          return null;
        },
        onSaved: (v) {
          if (v != null && _isOtherValue(v)) {
            final text = _otherControllers[q.id]?.text.trim() ?? '';
            _otherControllers[q.id]?.text = text;
            _answers[q.id] = text.isNotEmpty ? text : null;
          } else {
            _answers[q.id] = v;
          }
        },
      );
    }

    if (q.isMultiSelect) {
      final current = (_answers[q.id] as List?)?.cast<String>().toSet() ??
          const <String>{};
      return FormField<Set<String>>(
        initialValue: current,
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
      focusNode: _focusNodes[q.id],
      controller: _textControllers[q.id],
      textInputAction: isLast ? TextInputAction.done : TextInputAction.next,
      onFieldSubmitted: (_) => _nextOrSubmit(),
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
