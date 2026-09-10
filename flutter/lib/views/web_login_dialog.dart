import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import '../state/app_state.dart';

/// Web sign-in prompt. Same fields as the add-server dialog minus the server
/// URL, since the web build always talks to the same origin.
class WebLoginDialog extends StatefulWidget {
  const WebLoginDialog({super.key});

  @override
  State<WebLoginDialog> createState() => _WebLoginDialogState();
}

class _WebLoginDialogState extends State<WebLoginDialog> {
  final _formKey = GlobalKey<FormState>();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _totp = TextEditingController();
  final _totpFocus = FocusNode();
  bool _showTotp = false;
  bool _loading = false;
  String _error = '';

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    _totp.dispose();
    _totpFocus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _error = '';
      _loading = true;
    });
    try {
      final state = context.read<AppState>();
      final error = await state.webLogin(
        username: _username.text.trim(),
        password: _password.text,
        totp: _totp.text.trim().isEmpty ? null : _totp.text.trim(),
      );
      if (!mounted) return;
      if (error != null) {
        final l = l10n(context);
        setState(() {
          _error = error;
          _showTotp = _showTotp || error == l.totpPrompt;
        });
        return;
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = '$e');
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = l10n(context);

    String? validateRequired(String? value) {
      return value == null || value.trim().isEmpty ? l.required : null;
    }

    String? validatePassword(String? value) {
      return value == null || value.isEmpty ? l.required : null;
    }

    return Stack(
      children: [
        ModalBarrier(
          color: theme.colorScheme.scrim.withValues(alpha: 0.4),
          dismissible: false,
        ),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Card(
              margin: const EdgeInsets.all(24),
              elevation: 3,
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Form(
                  key: _formKey,
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          l.signInToYourAccount,
                          style: theme.textTheme.headlineSmall,
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _username,
                          decoration: InputDecoration(
                            labelText: l.username,
                          ),
                          validator: validateRequired,
                          enabled: !_loading,
                          textInputAction: TextInputAction.next,
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _password,
                          decoration: InputDecoration(
                            labelText: l.password,
                          ),
                          obscureText: true,
                          validator: validatePassword,
                          enabled: !_loading,
                          textInputAction: _showTotp
                              ? TextInputAction.next
                              : TextInputAction.done,
                          onFieldSubmitted: (_) {
                            if (_showTotp) {
                              _totpFocus.requestFocus();
                            } else {
                              unawaited(_submit());
                            }
                          },
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _totp,
                          focusNode: _totpFocus,
                          decoration: InputDecoration(
                            labelText: l.totpCode,
                            hintText: l.totpHint,
                            helperText:
                                _showTotp ? null : l.totpOptional,
                          ),
                          validator: _showTotp ? validateRequired : null,
                          keyboardType: TextInputType.number,
                          enabled: !_loading,
                          textInputAction: TextInputAction.done,
                          onFieldSubmitted: (_) => unawaited(_submit()),
                        ),
                        if (_error.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          Text(
                            _error,
                            style: TextStyle(
                              color: theme.colorScheme.error,
                            ),
                          ),
                        ],
                        const SizedBox(height: 20),
                        FilledButton(
                          onPressed: _loading ? null : () => unawaited(_submit()),
                          child: _loading
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Text(l.signIn),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
