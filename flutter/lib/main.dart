import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'l10n/l10n.dart';
import 'services/window_service.dart';
import 'state/app_state.dart';
import 'theme/theme.dart';
import 'views/app_view.dart';
import 'views/auth_views.dart';
import 'views/dialogs.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeWindow();

  final themeProvider = ThemeProvider();
  await themeProvider.loadInitial();

  final appState = AppState();
  appState.bootstrap();

  runApp(DevinoriumApp(
    appState: appState,
    themeProvider: themeProvider,
  ));
}

class DevinoriumApp extends StatefulWidget {
  final AppState appState;
  final ThemeProvider themeProvider;

  const DevinoriumApp({
    super.key,
    required this.appState,
    required this.themeProvider,
  });

  @override
  State<DevinoriumApp> createState() => _DevinoriumAppState();
}

class _DevinoriumAppState extends State<DevinoriumApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    _updateBrightness();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() {
    _updateBrightness();
  }

  void _updateBrightness() {
    final brightness =
        WidgetsBinding.instance.platformDispatcher.platformBrightness;
    widget.themeProvider.setPlatformBrightness(brightness);
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: widget.appState),
        ChangeNotifierProvider<ThemeProvider>.value(value: widget.themeProvider),
      ],
      child: Builder(
        builder: (context) {
          final locale = context.select<AppState, Locale>(
            (state) => state.locale,
          );
          final theme = context.watch<ThemeProvider>();
          return MaterialApp(
            onGenerateTitle: (context) => l10n(context).appTitle,
            debugShowCheckedModeBanner: false,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: locale,
            theme: theme.lightTheme,
            darkTheme: theme.darkTheme,
            themeMode: theme.themeMode,
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
    return Selector<AppState, AppView>(
      selector: (_, state) => state.view,
      builder: (context, view, _) {
        final Widget body = switch (view) {
          AppView.loading => const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            ),
          AppView.login => const LoginView(),
          AppView.app => const AppShell(),
        };

        return Stack(
          children: [
            body,
            const _DialogOverlay(),
            const _GlobalErrorBanner(),
          ],
        );
      },
    );
  }
}

class _DialogOverlay extends StatelessWidget {
  const _DialogOverlay();

  @override
  Widget build(BuildContext context) {
    return Selector<AppState, DialogKind>(
      selector: (_, state) => state.dialog,
      builder: (context, dialog, _) {
        if (dialog == DialogKind.none) return const SizedBox.shrink();
        return const DialogLayer();
      },
    );
  }
}

class _GlobalErrorBanner extends StatelessWidget {
  const _GlobalErrorBanner();

  @override
  Widget build(BuildContext context) {
    return Selector<AppState, String>(
      selector: (_, state) => state.globalError,
      builder: (context, globalError, _) {
        if (globalError.isEmpty) return const SizedBox.shrink();
        final state = context.read<AppState>();
        return Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Material(
            color: Theme.of(context).colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  Icon(
                    Icons.error_outline,
                    color: Theme.of(context).colorScheme.onErrorContainer,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      globalError,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onErrorContainer,
                      ),
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
        );
      },
    );
  }
}
