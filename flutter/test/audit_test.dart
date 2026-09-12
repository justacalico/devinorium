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

final _auditJson = [
  {
    'id': 3,
    'user_id': 1,
    'username': 'owner',
    'action': 'user.create',
    'detail': {'created_user_id': 2, 'username': 'alice'},
    'ip_hash': null,
    'created_at': '2026-09-10T12:00:00.000Z',
  },
  {
    'id': 2,
    'user_id': 1,
    'username': 'owner',
    'action': 'login',
    'detail': <String, dynamic>{},
    'ip_hash': 'a1b2c3d4e5f67890',
    'created_at': '2026-09-10T08:30:00.000Z',
  },
  {
    'id': 1,
    'user_id': null,
    'username': null,
    'action': 'server.start',
    'detail': <String, dynamic>{},
    'ip_hash': null,
    'created_at': '2026-09-10T08:00:00.000Z',
  },
];

User _owner() => User(
  id: 1,
  username: 'owner',
  role: 'user',
  totpEnabled: false,
  isOwner: true,
  providerId: 'devin-cli',
  providerCommand: 'devin',
);

void main() {
  group('AuditEntry.fromJson', () {
    test('parses all fields', () {
      final e = AuditEntry.fromJson(_auditJson[0]);
      expect(e.id, 3);
      expect(e.userId, 1);
      expect(e.username, 'owner');
      expect(e.action, 'user.create');
      expect(e.detail['username'], 'alice');
      expect(e.createdAt, '2026-09-10T12:00:00.000Z');
    });

    test('tolerates missing fields and string detail', () {
      final e = AuditEntry.fromJson({
        'id': 9,
        'action': 'login',
        'detail': '{"k": 1}',
      });
      expect(e.userId, isNull);
      expect(e.username, isNull);
      expect(e.detail, {'k': 1});
      expect(AuditEntry.fromJson(const {'id': 1}).action, '');
    });
  });

  group('ApiService.listAudit', () {
    test('requests the audit endpoint with pagination params', () async {
      String? seenPath;
      String? seenQuery;
      final mock = MockClient((req) async {
        seenPath = req.url.path;
        seenQuery = req.url.query;
        return http.Response(
          jsonEncode(_auditJson),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final service = ApiService(client: ApiClient.withClient(mock));
      final entries = await service.listAudit(limit: 50, offset: 100);
      expect(seenPath, '/api/audit');
      expect(seenQuery, contains('limit=50'));
      expect(seenQuery, contains('offset=100'));
      expect(entries, hasLength(3));
      expect(entries.first.action, 'user.create');
    });
  });

  group('Audit settings section', () {
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

    int auditIndex(AppState state) {
      final topics = settingsTopics(
        state.isOwner,
        lookupAppLocalizations(const Locale('en')),
      );
      return topics.indexWhere((t) => t.topic == SettingsTopic.audit);
    }

    testWidgets('is owner-only in the topic list', (tester) async {
      final l = lookupAppLocalizations(const Locale('en'));
      expect(
        settingsTopics(true, l).any((t) => t.topic == SettingsTopic.audit),
        isTrue,
      );
      expect(
        settingsTopics(false, l).any((t) => t.topic == SettingsTopic.audit),
        isFalse,
      );
    });

    testWidgets('lists entries from the server', (tester) async {
      final mock = MockClient((req) async {
        return http.Response(
          jsonEncode(_auditJson),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final state = AppState.test(
        api: ApiService(client: ApiClient.withClient(mock)),
        user: _owner(),
      );

      await tester.pumpWidget(buildWithState(state));
      await tester.pumpAndSettle();

      state.setSettingsTopicIndex(auditIndex(state));
      await tester.pumpAndSettle();

      expect(find.text('user.create'), findsOneWidget);
      expect(find.text('login'), findsOneWidget);
      expect(find.text('server.start'), findsOneWidget);
      // Null-user entry falls back to the system label.
      expect(find.text('system'), findsOneWidget);
    });

    testWidgets('shows empty state when there are no entries', (tester) async {
      final mock = MockClient((req) async {
        return http.Response(
          '[]',
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final state = AppState.test(
        api: ApiService(client: ApiClient.withClient(mock)),
        user: _owner(),
      );

      await tester.pumpWidget(buildWithState(state));
      await tester.pumpAndSettle();

      state.setSettingsTopicIndex(auditIndex(state));
      await tester.pumpAndSettle();

      expect(find.text('No audit entries yet.'), findsOneWidget);
    });

    testWidgets('shows error and retries', (tester) async {
      var fail = true;
      final mock = MockClient((req) async {
        if (fail) {
          return http.Response('{"error":"forbidden"}', 403);
        }
        return http.Response(
          jsonEncode(_auditJson),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final state = AppState.test(
        api: ApiService(client: ApiClient.withClient(mock)),
        user: _owner(),
      );

      await tester.pumpWidget(buildWithState(state));
      await tester.pumpAndSettle();

      state.setSettingsTopicIndex(auditIndex(state));
      await tester.pumpAndSettle();

      expect(find.text('Failed to load the audit log'), findsOneWidget);

      fail = false;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();

      expect(find.text('user.create'), findsOneWidget);
    });

    testWidgets('loads more pages', (tester) async {
      final page1 = [
        for (var i = 0; i < 50; i++)
          {
            'id': 100 - i,
            'user_id': 1,
            'username': 'owner',
            'action': 'action.$i',
            'detail': <String, dynamic>{},
            'ip_hash': null,
            'created_at': '2026-09-10T08:00:00.000Z',
          },
      ];
      final mock = MockClient((req) async {
        final offset = int.tryParse(req.url.queryParameters['offset'] ?? '') ?? 0;
        return http.Response(
          jsonEncode(offset == 0 ? page1 : _auditJson),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final state = AppState.test(
        api: ApiService(client: ApiClient.withClient(mock)),
        user: _owner(),
      );

      await tester.pumpWidget(buildWithState(state));
      await tester.pumpAndSettle();

      state.setSettingsTopicIndex(auditIndex(state));
      await tester.pumpAndSettle();

      expect(find.text('action.0'), findsOneWidget);
      expect(find.text('user.create'), findsNothing);

      await tester.ensureVisible(find.text('Load more'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Load more'));
      await tester.pumpAndSettle();

      expect(find.text('user.create'), findsOneWidget);
      expect(find.text('Load more'), findsNothing);
    });
  });
}
