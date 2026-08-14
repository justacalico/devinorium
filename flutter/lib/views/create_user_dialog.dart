import 'package:devinorium_frontend/state/app_state.dart';
import 'package:flutter/material.dart';

import '../l10n/l10n.dart';

class CreateUserDialog extends StatefulWidget {
  final AppState state;

  const CreateUserDialog({super.key, required this.state});

  @override
  State<CreateUserDialog> createState() => _CreateUserDialogState();
}

class _CreateUserDialogState extends State<CreateUserDialog> {
  final _formKey = GlobalKey<FormState>();
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _obscure = true;
  bool _creating = false;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _creating = true);
    await widget.state.createUser(
      username: _username.text,
      password: _password.text,
    );
    if (mounted) {
      setState(() => _creating = false);
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(l10n(context).createUser),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _username,
              decoration: InputDecoration(
                labelText: l10n(context).username,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              textInputAction: TextInputAction.next,
              enabled: !_creating,
              validator: (v) =>
                  v == null || v.trim().isEmpty ? l10n(context).required : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _password,
              decoration: InputDecoration(
                labelText: l10n(context).password,
                border: const OutlineInputBorder(),
                isDense: true,
                suffixIcon: IconButton(
                  icon: Icon(_obscure
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
              obscureText: _obscure,
              textInputAction: TextInputAction.done,
              enabled: !_creating,
              validator: (v) {
                if (v == null || v.isEmpty) return l10n(context).required;
                if (v.length < 12) return l10n(context).atLeast12Characters;
                return null;
              },
              onFieldSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _creating ? null : () => Navigator.of(context).pop(),
          child: Text(l10n(context).cancel),
        ),
        FilledButton(
          onPressed: _creating ? null : _submit,
          child: _creating
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(l10n(context).create),
        ),
      ],
    );
  }
}
