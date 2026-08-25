import 'dart:async';
import 'dart:convert';

import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/issue/gitlab_issue_provider.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';

http.Response _json(int status, Object body) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );

void main() {
  group('GitLabIssueProvider', () {
    test('canHandle matches GitLab issue URLs', () {
      expect(
        GitLabIssueProvider.canHandleUrl(
          'https://gitlab.com/group/project/-/issues/1',
        ),
        isTrue,
      );
      expect(
        GitLabIssueProvider.canHandleUrl(
          'https://gitlab.example.com/group/sub/project/-/issues/42',
        ),
        isTrue,
      );
      expect(
        GitLabIssueProvider.canHandleUrl(
          'https://gitlab.com/group/project/-/work_items/77',
        ),
        isTrue,
      );
      expect(
        GitLabIssueProvider.canHandleUrl(
          'https://gitlab.example.com/group/sub/project/-/work_items/3',
        ),
        isTrue,
      );
      expect(
        GitLabIssueProvider.canHandleUrl(
          'https://gitlab.com/group/project/-/merge_requests/1',
        ),
        isFalse,
      );
      expect(
        GitLabIssueProvider.canHandleUrl('https://github.com/a/b/issues/1'),
        isFalse,
      );
    });

    test('rejects URLs missing the /-/ separator', () {
      expect(
        GitLabIssueProvider.canHandleUrl(
          'https://gitlab.com/group/project/issues/1',
        ),
        isFalse,
      );
    });

    test('rejects non-numeric iids', () {
      expect(
        GitLabIssueProvider.canHandleUrl(
          'https://gitlab.com/group/project/-/issues/abc',
        ),
        isFalse,
      );
    });

    test('rejects URLs with no project path', () {
      expect(
        GitLabIssueProvider.canHandleUrl('https://gitlab.com/-/issues/1'),
        isFalse,
      );
    });

    test('rejects non-http schemes', () {
      expect(
        GitLabIssueProvider.canHandleUrl('ftp://gitlab.com/a/b/-/issues/1'),
        isFalse,
      );
    });

    test('loads issue and notes', () async {
      final mock = MockClient((req) async {
        final path = req.url.queryParameters['path'] ?? '';

        if (path.endsWith('/issues/1')) {
          return _json(200, {
            'iid': 1,
            'title': 'Bug in login',
            'description': '## Steps\n\n1. Open the app',
            'state': 'opened',
            'web_url': 'https://gitlab.com/group/project/-/issues/1',
            'author': {'name': 'Dev', 'username': 'dev'},
            'created_at': '2026-01-01T00:00:00Z',
            'updated_at': '2026-01-02T00:00:00Z',
            'labels': ['bug', 'frontend'],
            'milestone': {'title': 'v1.0'},
            'assignees': [
              {'name': 'Alice', 'username': 'alice'},
            ],
          });
        }

        if (path.contains('/notes')) {
          return _json(200, [
            {
              'author': {'name': 'Reviewer', 'username': 'reviewer'},
              'body': 'Confirmed',
              'created_at': '2026-01-02T00:00:00Z',
              'system': false,
            },
          ]);
        }

        return _json(404, {'error': 'unexpected'});
      });

      final client = ApiClient.withClient(mock);
      final provider = GitLabIssueProvider(client);
      await provider.load('https://gitlab.com/group/project/-/issues/1');

      expect(provider.value.isReady, isTrue);
      final detail = provider.value.valueOrNull!;
      expect(detail.title, 'Bug in login');
      expect(detail.iid, 1);
      expect(detail.isOpen, isTrue);
      expect(detail.author?.username, 'dev');
      expect(detail.labels, ['bug', 'frontend']);
      expect(detail.milestone, 'v1.0');
      expect(detail.assignees.first.username, 'alice');
      expect(detail.comments.length, 1);
      expect(detail.comments.first.body, 'Confirmed');
      expect(detail.comments.first.author?.username, 'reviewer');
    });

    test('handles a closed issue with no description', () async {
      final mock = MockClient((req) async {
        final path = req.url.queryParameters['path'] ?? '';
        if (path.endsWith('/issues/5')) {
          return _json(200, {
            'iid': 5,
            'title': 'Old issue',
            'state': 'closed',
            'web_url': 'https://gitlab.com/group/project/-/issues/5',
          });
        }
        if (path.contains('/notes')) {
          return _json(200, {'_list': []});
        }
        return _json(404, {'error': 'unexpected'});
      });

      final provider = GitLabIssueProvider(ApiClient.withClient(mock));
      await provider.load('https://gitlab.com/group/project/-/issues/5');

      expect(provider.value.isReady, isTrue);
      final detail = provider.value.valueOrNull!;
      expect(detail.isClosed, isTrue);
      expect(detail.description, '');
      expect(detail.comments, isEmpty);
      expect(detail.labels, isEmpty);
      expect(detail.milestone, isNull);
    });

    test('sends the host of self-managed instances', () async {
      String? seenHost;
      final mock = MockClient((req) async {
        seenHost = req.url.queryParameters['hostname'];
        final path = req.url.queryParameters['path'] ?? '';
        if (path.endsWith('/issues/42')) {
          return _json(200, {'iid': 42, 'title': 'x', 'state': 'opened'});
        }
        return _json(200, {'_list': []});
      });

      final provider = GitLabIssueProvider(ApiClient.withClient(mock));
      await provider.load(
        'https://gitlab.example.com/group/sub/project/-/issues/42',
      );

      expect(seenHost, 'gitlab.example.com');
      expect(provider.value.valueOrNull?.iid, 42);
    });

    test('loads work_item URLs using the issue API', () async {
      final seen = <String>[];
      final mock = MockClient((req) async {
        final path = req.url.queryParameters['path'] ?? '';
        seen.add(path);
        if (path.endsWith('/issues/77')) {
          return _json(200, {
            'iid': 77,
            'title': 'Work item as issue',
            'state': 'opened',
            'web_url': 'https://gitlab.com/g/p/-/work_items/77',
          });
        }
        if (path.contains('/notes')) {
          return _json(200, {'_list': []});
        }
        return _json(404, {});
      });

      final provider = GitLabIssueProvider(ApiClient.withClient(mock));
      await provider.load('https://gitlab.com/g/p/-/work_items/77');

      expect(provider.value.isReady, isTrue);
      expect(provider.value.valueOrNull?.iid, 77);
      expect(seen.any((p) => p.contains('/issues/77')), isTrue);
    });

    test('surfaces fetch errors', () async {
      final mock = MockClient((_) async => _json(500, {'error': 'gitlab down'}));

      final provider = GitLabIssueProvider(ApiClient.withClient(mock));
      await provider.load('https://gitlab.com/group/project/-/issues/1');

      expect(provider.value.isError, isTrue);
    });

    test('rejects unsupported URLs', () async {
      final provider = GitLabIssueProvider(
        ApiClient.withClient(MockClient((_) async => _json(200, {}))),
      );
      await provider.load('https://example.com');

      expect(provider.value.isError, isTrue);
      expect(
        '${provider.value.errorOrNull}',
        contains('Not a supported GitLab issue URL'),
      );
    });

    test('does not notify after being disposed', () async {
      final gate = Completer<void>();
      final mock = MockClient((req) async {
        final path = req.url.queryParameters['path'] ?? '';
        if (path.contains('/notes')) {
          await gate.future;
          return _json(200, {'_list': []});
        }
        if (path.endsWith('/issues/1')) {
          return _json(200, {'iid': 1, 'title': 'x', 'state': 'opened'});
        }
        return _json(404, {});
      });

      final provider = GitLabIssueProvider(ApiClient.withClient(mock));
      final loading = provider.load('https://gitlab.com/group/project/-/issues/1');
      provider.dispose();
      gate.complete();

      await loading;
      expect(provider.value.isReady, isTrue);
    });

    test('ignores a stale fetch after a newer load', () async {
      final gates = <int, Completer<void>>{
        1: Completer<void>(),
        2: Completer<void>(),
      };

      int iidFromPath(String path) {
        final match = RegExp(r'/issues/(\d+)').firstMatch(path);
        return match == null ? 0 : int.parse(match.group(1)!);
      }

      final mock = MockClient((req) async {
        final path = req.url.queryParameters['path'] ?? '';
        final iid = iidFromPath(path);
        if (path.contains('/notes')) {
          await gates[iid]!.future;
          return _json(200, {'_list': []});
        }
        if (path.contains('/issues/')) {
          return _json(200, {'iid': iid, 'title': 'Issue $iid', 'state': 'opened'});
        }
        return _json(404, {});
      });

      final provider = GitLabIssueProvider(ApiClient.withClient(mock));
      final first = provider.load('https://gitlab.com/group/project/-/issues/1');
      final second = provider.load('https://gitlab.com/group/project/-/issues/2');

      gates[2]!.complete();
      await second;
      gates[1]!.complete();
      await first;

      expect(provider.value.valueOrNull?.iid, 2);
    });
  });
}
