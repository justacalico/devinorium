import 'dart:convert';

import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/merge_request/gitlab_merge_request_provider.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';

http.Response _json(int status, Object body) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );

void main() {
  group('GitLabMergeRequestProvider', () {
    test('canHandle matches GitLab merge request URLs', () {
      expect(
        GitLabMergeRequestProvider.canHandleUrl(
          'https://gitlab.com/group/project/-/merge_requests/1',
        ),
        isTrue,
      );
      expect(
        GitLabMergeRequestProvider.canHandleUrl(
          'https://gitlab.example.com/group/sub/project/-/merge_requests/42',
        ),
        isTrue,
      );
      expect(
        GitLabMergeRequestProvider.canHandleUrl(
          'https://github.com/group/project/pull/1',
        ),
        isFalse,
      );
    });

    test('loads and combines merge request, diffs, and notes', () async {
      final mock = MockClient((req) async {
        final query = req.url.queryParameters;
        final path = query['path'] ?? '';

        if (path.endsWith('/merge_requests/1')) {
          return _json(200, {
            'iid': 1,
            'title': 'Add feature',
            'description': '## Summary\n\nAdds a feature.',
            'state': 'opened',
            'source_branch': 'feature',
            'target_branch': 'main',
            'web_url': 'https://gitlab.com/group/project/-/merge_requests/1',
            'draft': false,
            'has_conflicts': false,
            'author': {'name': 'Dev', 'username': 'dev'},
            'created_at': '2026-01-01T00:00:00Z',
            'updated_at': '2026-01-02T00:00:00Z',
          });
        }

        if (path.contains('/diffs')) {
          return _json(200, [
            {
              'old_path': 'a.txt',
              'new_path': 'a.txt',
              'diff': '@@ -0,0 +1 @@\n+hello',
              'new_file': true,
              'deleted_file': false,
              'renamed_file': false,
            },
          ]);
        }

        if (path.contains('/notes')) {
          return _json(200, [
            {
              'author': {'name': 'Reviewer', 'username': 'reviewer'},
              'body': 'Looks good',
              'created_at': '2026-01-02T00:00:00Z',
              'system': false,
            },
          ]);
        }

        if (req.url.path == '/api/git-connections/gitlab/pipelines') {
          return _json(200, {
            'status': 'success',
            'name': 'test-and-build',
            'web_url': 'https://gitlab.com/group/project/-/pipelines/42',
            'ref_name': 'feature',
          });
        }

        return _json(404, {'error': 'unexpected'});
      });

      final client = ApiClient.withClient(mock);
      final provider = GitLabMergeRequestProvider(client);
      await provider.load('https://gitlab.com/group/project/-/merge_requests/1');

      expect(provider.value.isReady, isTrue);
      final detail = provider.value.valueOrNull!;
      expect(detail.title, 'Add feature');
      expect(detail.sourceBranch, 'feature');
      expect(detail.targetBranch, 'main');
      expect(detail.isOpen, isTrue);
      expect(detail.author?.username, 'dev');
      expect(detail.changes.length, 1);
      expect(detail.changes.first.newFile, isTrue);
      expect(detail.comments.length, 1);
      expect(detail.comments.first.body, 'Looks good');
      expect(detail.pipeline, isNotNull);
      expect(detail.pipeline!.status, 'success');
      expect(detail.pipeline!.name, 'test-and-build');
      expect(detail.pipeline!.webUrl,
          'https://gitlab.com/group/project/-/pipelines/42');
      expect(detail.pipeline!.refName, 'feature');
    });

    test('loads with no pipeline when endpoint returns 204', () async {
      final mock = MockClient((req) async {
        if (req.url.path == '/api/git-connections/gitlab/pipelines') {
          return http.Response('', 204);
        }

        final query = req.url.queryParameters;
        final path = query['path'] ?? '';

        if (path.endsWith('/merge_requests/1')) {
          return _json(200, {
            'iid': 1,
            'title': 'Add feature',
            'state': 'opened',
            'source_branch': 'feature',
            'target_branch': 'main',
            'web_url': 'https://gitlab.com/group/project/-/merge_requests/1',
          });
        }

        if (path.contains('/diffs')) {
          return _json(200, {'_list': []});
        }

        if (path.contains('/notes')) {
          return _json(200, {'_list': []});
        }

        return _json(404, {'error': 'unexpected'});
      });

      final client = ApiClient.withClient(mock);
      final provider = GitLabMergeRequestProvider(client);
      await provider.load('https://gitlab.com/group/project/-/merge_requests/1');

      expect(provider.value.isReady, isTrue);
      expect(provider.value.valueOrNull?.pipeline, isNull);
    });

    test('rejects unsupported URLs', () async {
      final provider = GitLabMergeRequestProvider(
        ApiClient.withClient(MockClient((_) async => _json(404, {}))),
      );
      await provider.load('https://example.com');

      expect(provider.value.isError, isTrue);
      expect(
        '${provider.value.errorOrNull}',
        contains('Not a supported GitLab merge request URL'),
      );
    });
  });
}
