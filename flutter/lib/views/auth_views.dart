import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import '../state/app_state.dart';

class LoginView extends StatefulWidget {
  const LoginView({super.key});

  @override
  State<LoginView> createState() => _LoginViewState();
}

class _LoginViewState extends State<LoginView> {
  final _formKey = GlobalKey<FormState>();
  final _serverUrl = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _totp = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _serverUrl.dispose();
    _username.dispose();
    _password.dispose();
    _totp.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    final state = context.read<AppState>();
    state.doLogin(
      serverUrl: _serverUrl.text,
      username: _username.text,
      password: _password.text,
      totp: _totp.text,
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final state = context.read<AppState>();
      if (state.api.client.isNative) {
        final url = await state.api.client.serverUrl;
        if (url != null && url.isNotEmpty) {
          _serverUrl.text = url;
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Card(
            margin: const EdgeInsets.all(24),
            elevation: 2,
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Form(
                key: _formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(Icons.smart_toy_outlined,
                        size: 56, color: theme.colorScheme.primary),
                    const SizedBox(height: 12),
                    Text(l10n(context).appTitle,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineSmall),
                    const SizedBox(height: 4),
                    Text(l10n(context).signInToYourAccount,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant)),
                    const SizedBox(height: 24),
                    if (state.api.client.isNative) ...[
                      TextFormField(
                        controller: _serverUrl,
                        decoration: InputDecoration(
                          labelText: l10n(context).serverUrl,
                          hintText: l10n(context).serverUrlHint,
                          border: const OutlineInputBorder(),
                        ),
                        keyboardType: TextInputType.url,
                        textInputAction: TextInputAction.next,
                        validator: (v) {
                          if (v == null || v.trim().isEmpty) {
                            return l10n(context).required;
                          }
                          final trimmed = v.trim();
                          if (!trimmed.startsWith('http://') &&
                              !trimmed.startsWith('https://')) {
                            return l10n(context).serverUrlInvalid;
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 16),
                    ],
                    TextFormField(
                      controller: _username,
                      decoration: InputDecoration(
                        labelText: l10n(context).username,
                        border: const OutlineInputBorder(),
                      ),
                      textInputAction: TextInputAction.next,
                      validator: (v) =>
                          v == null || v.trim().isEmpty ? l10n(context).required : null,
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _password,
                      decoration: InputDecoration(
                        labelText: l10n(context).password,
                        border: const OutlineInputBorder(),
                        suffixIcon: IconButton(
                          icon: Icon(_obscure
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined),
                          onPressed: () =>
                              setState(() => _obscure = !_obscure),
                        ),
                      ),
                      obscureText: _obscure,
                      textInputAction: TextInputAction.done,
                      validator: (v) =>
                          v == null || v.isEmpty ? l10n(context).required : null,
                      onFieldSubmitted: (_) => _submit(),
                    ),
                    if (state.showTotpField) ...[
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _totp,
                        decoration: InputDecoration(
                          labelText: l10n(context).totpCode,
                          hintText: l10n(context).totpHint,
                          border: const OutlineInputBorder(),
                        ),
                        keyboardType: TextInputType.number,
                      ),
                    ],
                    const SizedBox(height: 20),
                    FilledButton(
                      onPressed: _submit,
                      child: Text(l10n(context).signIn),
                    ),
                    if (state.loginError.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text(state.loginError,
                          style: TextStyle(color: theme.colorScheme.error)),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
