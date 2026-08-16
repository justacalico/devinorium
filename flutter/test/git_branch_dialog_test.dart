import 'dart:convert';

import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/api/api_service.dart';
import 'package:devinorium_frontend/generated/l10n/app_localizations.dart';
import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:devinorium_frontend/views/git_branch_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

http.Response _json(int status, Object body) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );

void main() {
  group('GitBranchDialog', () {
    testWidgets('uses active thread branch as current and disables its buttons', (tester) async {
      final client = ApiClient.withClient(MockClient((req) async {
        final path = req.url.path;
        if (path == '/api/projects/1/git') {
          return _json(200, {
            'is_repo': true,
            'branch': 'main',
            'worktree_path': '/x',
            'toplevel': '/x',
            'common_dir': '/x/.git',
          });
        }
        if (path == '/api/projects/1/git/branches') {
          return _json(200, {
            'branches': [
              {
                'name': 'main',
                'refname': 'refs/heads/main',
                'is_current': true,
                'is_default': true,
                'is_remote': false,
                'committer_date': 0,
              },
              {
                'name': 'fix-hot-reload',
                'refname': 'refs/heads/fix-hot-reload',
                'is_current': false,
                'is_default': false,
                'is_remote': false,
                'committer_date': 0,
              },
            ],
          });
        }
        if (path == '/api/projects/1/git/worktrees') {
          return _json(200, []);
        }
        return _json(404, {'error': 'unexpected request'});
      }));

      final thread = Thread(
        id: 't1',
        title: 'thread',
        projectId: 1,
        model: '',
        permissionMode: 'normal',
        branch: 'fix-hot-reload',
        createdAt: '',
        updatedAt: '',
      );
      final state = AppState.test(
        api: ApiService(client: client),
        activeThreadDetail: ThreadDetail(thread: thread, messages: const []),
      );
      await state.openGitBranchDialog(1);

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: state,
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(body: GitBranchDialog()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('fix-hot-reload'), findsAtLeastNWidgets(1));
      expect(find.byIcon(Icons.check_circle), findsOneWidget);

      final fixTile = find.ancestor(
        of: find.text('fix-hot-reload'),
        matching: find.byType(ListTile),
      );
      final useButton = find.descendant(
        of: fixTile,
        matching: find.widgetWithText(TextButton, 'Use'),
      );
      final checkoutButton = find.descendant(
        of: fixTile,
        matching: find.widgetWithText(TextButton, 'Checkout'),
      );
      expect(tester.widget<TextButton>(useButton).onPressed, isNull);
      expect(tester.widget<TextButton>(checkoutButton).onPressed, isNull);

      final mainTile = find.ancestor(
        of: find.text('main'),
        matching: find.byType(ListTile),
      );
      final mainUse = find.descendant(
        of: mainTile,
        matching: find.widgetWithText(TextButton, 'Use'),
      );
      final mainCheckout = find.descendant(
        of: mainTile,
        matching: find.widgetWithText(TextButton, 'Checkout'),
      );
      expect(tester.widget<TextButton>(mainUse).onPressed, isNotNull);
      expect(tester.widget<TextButton>(mainCheckout).onPressed, isNotNull);
    });
  });
}
