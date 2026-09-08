import 'dart:convert';

import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/api/api_service.dart';
import 'package:devinorium_frontend/l10n/l10n.dart';
import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:devinorium_frontend/theme/theme.dart';
import 'package:devinorium_frontend/views/settings/topics.dart';
import 'package:devinorium_frontend/views/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:flutter_test/flutter_test.dart';

final _usageJson = {
  'since_day': '2026-09-02',
  'until_day': '2026-09-08',
  'buckets': [
    {
      'day': '2026-09-02',
      'provider_id': 'devin-cli',
      'model': 'glm-5-2',
      'records': 2,
      'input_tokens': 1200,
      'output_tokens': 600,
      'thought_tokens': 0,
      'cached_read_tokens': 0,
      'cached_write_tokens': 0,
      'total_tokens': 1800,
      'cost_amount': 0.25,
      'cost_currency': 'USD',
    },
    {
      'day': '2026-09-05',
      'provider_id': 'opencode',
      'model': 'gpt-5',
      'records': 1,
      'input_tokens': 400,
      'output_tokens': 200,
      'thought_tokens': 100,
      'cached_read_tokens': 50,
      'cached_write_tokens': 0,
      'total_tokens': 600,
      'cost_amount': null,
      'cost_currency': null,
    },
  ],
  'totals': {
    'records': 3,
    'input_tokens': 1600,
    'output_tokens': 800,
    'thought_tokens': 100,
    'cached_read_tokens': 50,
    'cached_write_tokens': 0,
    'total_tokens': 2400,
    'costs': [
      {'currency': 'USD', 'amount': 0.25},
    ],
  },
};

void main() {
  group('UsageSummary.fromJson', () {
    test('parses buckets and totals', () {
      final summary = UsageSummary.fromJson(_usageJson);
      expect(summary.sinceDay, '2026-09-02');
      expect(summary.untilDay, '2026-09-08');
      expect(summary.buckets, hasLength(2));
      expect(summary.buckets[0].providerId, 'devin-cli');
      expect(summary.buckets[0].totalTokens, 1800);
      expect(summary.buckets[0].costAmount, 0.25);
      expect(summary.totals.totalTokens, 2400);
      expect(summary.totals.records, 3);
      expect(summary.totals.costs.single.currency, 'USD');
      expect(summary.totals.costs.single.amount, 0.25);
    });

    test('tolerates missing fields', () {
      final summary = UsageSummary.fromJson(const {});
      expect(summary.buckets, isEmpty);
      expect(summary.totals.totalTokens, 0);
    });
  });

  group('formatTokens', () {
    test('formats magnitudes with suffixes', () {
      expect(formatTokens(0), '0');
      expect(formatTokens(999), '999');
      expect(formatTokens(1500), '1.5K');
      expect(formatTokens(23_400_000), '23.4M');
      expect(formatTokens(2_010_000_000), '2.01B');
      expect(formatTokens(1_500_000_000_000), '1.5T');
    });
  });

  group('ApiService.usageSummary', () {
    test('requests the usage endpoint with window and timezone', () async {
      String? seenPath;
      String? seenQuery;
      final mock = MockClient((req) async {
        seenPath = req.url.path;
        seenQuery = req.url.query;
        return http.Response(
          jsonEncode(_usageJson),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final service = ApiService(client: ApiClient.withClient(mock));
      final summary = await service.usageSummary(days: 7);
      expect(seenPath, '/api/usage');
      expect(seenQuery, contains('days=7'));
      expect(seenQuery, contains('tz_offset='));
      expect(summary.totals.totalTokens, 2400);
    });
  });

  group('Usage settings section', () {
    Widget buildWithState(AppState state) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: MultiProvider(
        providers: [
          ChangeNotifierProvider<AppState>.value(value: state),
          ChangeNotifierProvider<ThemeProvider>(
            create: (_) => ThemeProvider()..loadInitial(),
          ),
        ],
        child: const SettingsPage(),
      ),
    );

    int usageIndex(AppState state) {
      final topics = settingsTopics(
        state.isOwner,
        lookupAppLocalizations(const Locale('en')),
      );
      return topics.indexWhere((t) => t.topic == SettingsTopic.usage);
    }

    testWidgets('shows totals and breakdowns from the server', (tester) async {
      final mock = MockClient((req) async {
        return http.Response(
          jsonEncode(_usageJson),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final state = AppState.test(
        api: ApiService(client: ApiClient.withClient(mock)),
        providers: [
          ProviderInfo(id: 'devin-cli', name: 'Devin CLI'),
          ProviderInfo(id: 'opencode', name: 'OpenCode'),
        ],
        user: User(
          id: 1,
          username: 'owner',
          role: 'user',
          totpEnabled: false,
          isOwner: true,
          providerId: 'devin-cli',
          providerCommand: 'devin',
        ),
      );

      await tester.pumpWidget(buildWithState(state));
      await tester.pumpAndSettle();

      state.setSettingsTopicIndex(usageIndex(state));
      await tester.pumpAndSettle();

      expect(find.text('Usage'), findsWidgets);
      expect(find.text('2.4K'), findsWidgets);
      expect(find.text('Usage by day'), findsOneWidget);
      expect(find.text('By provider'), findsOneWidget);
      expect(find.text('By model'), findsOneWidget);
      expect(find.text('Devin CLI'), findsWidgets);
      expect(find.textContaining('gpt-5'), findsOneWidget);
    });

    testWidgets('shows empty state when no usage recorded', (tester) async {
      final mock = MockClient((req) async {
        return http.Response(
          jsonEncode({
            'since_day': '2026-09-02',
            'until_day': '2026-09-08',
            'buckets': <dynamic>[],
            'totals': {
              'records': 0,
              'input_tokens': 0,
              'output_tokens': 0,
              'thought_tokens': 0,
              'cached_read_tokens': 0,
              'cached_write_tokens': 0,
              'total_tokens': 0,
              'costs': <dynamic>[],
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final state = AppState.test(
        api: ApiService(client: ApiClient.withClient(mock)),
        user: User(
          id: 1,
          username: 'owner',
          role: 'user',
          totpEnabled: false,
          isOwner: true,
          providerId: 'devin-cli',
          providerCommand: 'devin',
        ),
      );

      await tester.pumpWidget(buildWithState(state));
      await tester.pumpAndSettle();

      state.setSettingsTopicIndex(usageIndex(state));
      await tester.pumpAndSettle();

      expect(find.text('No usage recorded yet.'), findsOneWidget);
    });
  });
}
