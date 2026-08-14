import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'l10n/l10n.dart';
import 'state/app_state.dart';
import 'views/app_view.dart';
import 'views/auth_views.dart';
import 'views/dialogs.dart';
import 'views/pairing_setup_view.dart';

void main() {
  runApp(const DevinoriumApp());
}

class DevinoriumApp extends StatelessWidget {
  const DevinoriumApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => AppState()..bootstrap(),
      child: Builder(
        builder: (context) {
          final (themeMode, locale) = context.select<AppState, (ThemeMode, Locale)>(
            (state) => (state.themeMode, state.locale),
          );
          return MaterialApp(
            onGenerateTitle: (context) => l10n(context).appTitle,
            debugShowCheckedModeBanner: false,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: locale,
            theme: ThemeData(
              useMaterial3: true,
              colorSchemeSeed: const Color(0xFF6750A4),
              brightness: Brightness.light,
            ),
            darkTheme: ThemeData(
              useMaterial3: true,
              colorSchemeSeed: const Color(0xFF6750A4),
              brightness: Brightness.dark,
            ),
            themeMode: themeMode,
            home: const RootScaffold(),
          );
        },
      ),
    );
  }
}

class RootScaffold extends StatelessWidget {
  const RootScaffold({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final view = state.view;

    Widget body;
    switch (view) {
      case AppView.loading:
        body = const Scaffold(
          body: Center(child: CircularProgressIndicator()),
        );
        break;
      case AppView.login:
        body = const LoginView();
        break;
      case AppView.setup:
        body = const PairingSetupView();
        break;
      case AppView.app:
        body = const AppShell();
        break;
    }

    return Stack(
      children: [
        body,
        // Global dialogs rendered above the layout.
        if (state.dialog != DialogKind.none) const DialogLayer(),
        // Global error snackbar-ish banner.
        if (state.globalError.isNotEmpty)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Material(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 10),
                child: Row(
                  children: [
                    Icon(Icons.error_outline,
                        color: Theme.of(context).colorScheme.onErrorContainer),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        state.globalError,
                        style: TextStyle(
                            color:
                                Theme.of(context).colorScheme.onErrorContainer),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: state.clearGlobalError,
                      color: Theme.of(context).colorScheme.onErrorContainer,
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
