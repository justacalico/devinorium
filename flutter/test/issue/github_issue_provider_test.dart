import 'dart:convert';

import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/issue/github_issue_provider.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';

http.Response _json(int status, Object body) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

void main() {
  group('GitHubIssueProvider', () {
    test('canHandle matches GitHub issue URLs', () {
      expect(
        GitHubIssueProvider.canHandleUrl(
          'https://github.com/owner/repo/issues/1',
        ),
        isTrue,
      );
      expect(
        GitHubIssueProvider.canHandleUrl(
          'https://corp.ghe.com/owner/repo/issues/42',
        ),
        isTrue,
      );
      expect(
        GitHubIssueProvider.canHandleUrl(
          'https://gitlab.com/group/project/-/issues/1',
        ),
        isFalse,
      );
      expect(
        GitHubIssueProvider.canHandleUrl(
          'https://github.com/owner/repo/pull/1',
        ),
        isFalse,
      );
      expect(
        GitHubIssueProvider.canHandleUrl(
          'https://github.com/a/b/c/issues/1',
        ),
        isFalse,
      );
      expect(GitHubIssueProvider.canHandleUrl('not-a-url'), isFalse);
    });

    test('loads issue with comments, labels, and assignees', () async {
      final mock = MockClient((req) async {
        final path = req.url.queryParameters['path'] ?? '';
        if (path.endsWith('/issues/3/comments?per_page=100')) {
          return _json(200, [
            {
              'id': 1,
              'body': 'confirmed',
              'created_at': '2026-01-02T00:00:00Z',
              'user': {'login': 'triage', 'avatar_url': 'https://a/t.png'},
            },
          ]);
        }
        if (path.endsWith('/issues/3')) {
          return _json(200, {
            'number': 3,
            'title': 'Something broke',
            'body': 'it stopped working',
            'state': 'open',
            'html_url': 'https://github.com/owner/repo/issues/3',
            'labels': [
              {'name': 'bug'},
              {'name': 'ui'},
            ],
            'milestone': {'title': 'v1.0'},
            'assignees': [
              {'login': 'dev1', 'avatar_url': ''},
              {'login': 'dev2', 'avatar_url': ''},
            ],
            'user': {'login': 'reporter', 'avatar_url': 'https://a/r.png'},
            'created_at': '2026-01-01T00:00:00Z',
            'updated_at': '2026-01-03T00:00:00Z',
          });
        }
        return _json(404, {'error': 'not found'});
      });
      final provider = GitHubIssueProvider(ApiClient.withClient(mock));

      await provider.load('https://github.com/owner/repo/issues/3');

      final issue = provider.value.valueOrNull!;
      expect(issue.title, 'Something broke');
      expect(issue.description, 'it stopped working');
      expect(issue.state, 'open');
      expect(issue.iid, 3);
      expect(issue.webUrl, 'https://github.com/owner/repo/issues/3');
      expect(issue.labels, ['bug', 'ui']);
      expect(issue.milestone, 'v1.0');
      expect(issue.author!.username, 'reporter');
      expect(issue.assignees, hasLength(2));
      expect(issue.assignees[0].username, 'dev1');
      expect(issue.comments, hasLength(1));
      expect(issue.comments[0].body, 'confirmed');
      expect(issue.comments[0].author!.username, 'triage');
    });

    test('emits an error for non-issue URLs', () async {
      final provider = GitHubIssueProvider(
        ApiClient.withClient(MockClient((_) async => _json(200, {}))),
      );
      await provider.load('https://gitlab.com/g/p/-/issues/1');
      expect(provider.value.isError, isTrue);
    });
  });
}
