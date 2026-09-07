import 'package:devinorium_frontend/generated/l10n/app_localizations.dart';
import 'package:devinorium_frontend/generated/l10n/app_localizations_en.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:devinorium_frontend/views/thread_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

Widget _buildWithState(AppState state) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: ChangeNotifierProvider<AppState>.value(
    value: state,
    child: const ThreadPage(),
  ),
);

void main() {
  final l = AppLocalizationsEn();

  testWidgets('ThreadPage prompts to add a server when none is configured', (
    tester,
  ) async {
    final state = AppState.test();
    addTearDown(state.dispose);

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    expect(find.text(l.addServerFromSettingsPrompt), findsOneWidget);
    expect(find.widgetWithText(FilledButton, l.settings), findsOneWidget);
  });

  testWidgets('tapping the settings button opens settings', (tester) async {
    final state = AppState.test();
    addTearDown(state.dispose);

    await tester.pumpWidget(_buildWithState(state));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, l.settings));
    await tester.pumpAndSettle();

    expect(state.page, MainPage.settings);
  });
}
