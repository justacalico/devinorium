import 'package:devinorium_frontend/state/app_state.dart';
import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../models/models.dart';

class ChangePasswordDialog extends StatefulWidget {
  final AppState state;

  const ChangePasswordDialog({super.key, required this.state});

  @override
  State<ChangePasswordDialog> createState() => _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends State<ChangePasswordDialog> {
  final _formKey = GlobalKey<FormState>();
  final _current = TextEditingController();
  final _new = TextEditingController();
  final _confirm = TextEditingController();
  bool _obscure = true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _current.dispose();
    _new.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final error = await widget.state.changePassword(_current.text, _new.text);
    if (!mounted) return;
    if (error == null) {
      // The password change revoked this session; the state has already
      // routed back to login.
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _busy = false;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = l10n(context);
    return AlertDialog(
      title: Text(l.changePassword),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_error != null) ...[
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              const SizedBox(height: 12),
            ],
            TextFormField(
              controller: _current,
              decoration: InputDecoration(
                labelText: l.currentPassword,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              obscureText: _obscure,
              autofocus: true,
              textInputAction: TextInputAction.next,
              enabled: !_busy,
              validator: (v) => v == null || v.isEmpty ? l.required : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _new,
              decoration: InputDecoration(
                labelText: l.newPassword,
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
              textInputAction: TextInputAction.next,
              enabled: !_busy,
              validator: (v) {
                if (v == null || v.isEmpty) return l.required;
                if (v.length < 12) return l.atLeast12Characters;
                return null;
              },
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _confirm,
              decoration: InputDecoration(
                labelText: l.confirmNewPassword,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              obscureText: _obscure,
              textInputAction: TextInputAction.done,
              enabled: !_busy,
              validator: (v) =>
                  v != _new.text ? l.passwordsDoNotMatch : null,
              onFieldSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: Text(l.cancel),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(l.save),
        ),
      ],
    );
  }
}

class ResetPasswordDialog extends StatefulWidget {
  final AppState state;
  final User user;

  const ResetPasswordDialog({
    super.key,
    required this.state,
    required this.user,
  });

  @override
  State<ResetPasswordDialog> createState() => _ResetPasswordDialogState();
}

class _ResetPasswordDialogState extends State<ResetPasswordDialog> {
  final _formKey = GlobalKey<FormState>();
  final _password = TextEditingController();
  bool _obscure = true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final error =
        await widget.state.resetUserPassword(widget.user.id, _password.text);
    if (!mounted) return;
    if (error == null) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _busy = false;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = l10n(context);
    return AlertDialog(
      title: Text(l.resetPassword),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l.resetPasswordHint(widget.user.username)),
            const SizedBox(height: 12),
            if (_error != null) ...[
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              const SizedBox(height: 12),
            ],
            TextFormField(
              controller: _password,
              decoration: InputDecoration(
                labelText: l.newPassword,
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
              autofocus: true,
              textInputAction: TextInputAction.done,
              enabled: !_busy,
              validator: (v) {
                if (v == null || v.isEmpty) return l.required;
                if (v.length < 12) return l.atLeast12Characters;
                return null;
              },
              onFieldSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: Text(l.cancel),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(l.save),
        ),
      ],
    );
  }
}
