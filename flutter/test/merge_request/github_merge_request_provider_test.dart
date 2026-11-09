import 'dart:convert';
import 'dart:typed_data';

import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/merge_request/github_merge_request_provider.dart';
import 'package:devinorium_frontend/merge_request/merge_request_models.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';

http.Response _json(int status, Object body) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

void main() {
  group('GitHubMergeRequestProvider', () {
    test('canHandle matches GitHub pull request URLs', () {
      expect(
        GitHubMergeRequestProvider.canHandleUrl(
          'https://github.com/owner/repo/pull/1',
        ),
        isTrue,
      );
      expect(
        GitHubMergeRequestProvider.canHandleUrl(
          'https://corp.ghe.com/owner/repo/pull/42/files',
        ),
        isTrue,
      );
      expect(
        GitHubMergeRequestProvider.canHandleUrl(
          'https://gitlab.com/group/project/-/merge_requests/1',
        ),
        isFalse,
      );
      expect(
        GitHubMergeRequestProvider.canHandleUrl(
          'https://github.com/owner/repo/issues/1',
        ),
        isFalse,
      );
      expect(GitHubMergeRequestProvider.canHandleUrl('not-a-url'), isFalse);
    });

    test('reports pipeline and file support', () {
      final provider = GitHubMergeRequestProvider(
        ApiClient.withClient(MockClient((_) async => _json(200, {}))),
      );
      expect(provider.supportsPipelines, isTrue);
      expect(provider.supportsFiles, isTrue);
    });

    test('loads and combines pull request, files, comments, and runs', () async {
      final mock = MockClient((req) async {
        final path = req.url.queryParameters['path'] ?? '';
        final uriPath = req.url.path;

        if (path.endsWith('/pulls/7/files?per_page=100')) {
          return _json(200, [
            {
              'filename': 'lib/a.dart',
              'status': 'modified',
              'patch': '@@ -1 +1 @@\n-old\n+new',
            },
            {'filename': 'lib/b.dart', 'status': 'added', 'patch': '@@ -0,0 +1 @@\n+new'},
            {
              'filename': 'lib/c.dart',
              'status': 'renamed',
              'previous_filename': 'lib/old.dart',
              'patch': '@@ -1 +1 @@\n-a\n+b',
            },
          ]);
        }
        if (path.endsWith('/issues/7/comments?per_page=100')) {
          return _json(200, [
            {
              'id': 1,
              'body': 'looks good',
              'created_at': '2026-01-02T00:00:00Z',
              'user': {'login': 'reviewer', 'avatar_url': 'https://a/u.png'},
            },
          ]);
        }
        if (path.endsWith('/pulls/7')) {
          return _json(200, {
            'number': 7,
            'title': 'Add feature',
            'body': '## Summary\n\nAdds a feature.',
            'state': 'open',
            'draft': false,
            'mergeable': true,
            'auto_merge': null,
            'html_url': 'https://github.com/owner/repo/pull/7',
            'head': {'ref': 'feature', 'sha': 'deadbeef'},
            'base': {'ref': 'main', 'sha': 'beefdead'},
            'user': {'login': 'author', 'avatar_url': 'https://a/me.png'},
            'created_at': '2026-01-01T00:00:00Z',
            'updated_at': '2026-01-03T00:00:00Z',
          });
        }
        if (uriPath == '/api/git-connections/github/pipelines') {
          return _json(200, [
            {
              'id': 42,
              'status': 'success',
              'name': 'CI',
              'web_url': 'https://github.com/o/r/actions/runs/42',
              'ref_name': 'feature',
              'created_at': '2026-01-01T00:00:00Z',
              'updated_at': '2026-01-02T00:00:00Z',
            },
          ]);
        }
        return _json(404, {'error': 'not found'});
      });
      final provider = GitHubMergeRequestProvider(ApiClient.withClient(mock));

      await provider.load('https://github.com/owner/repo/pull/7');

      final detail = provider.value.valueOrNull!;
      expect(detail.title, 'Add feature');
      expect(detail.state, 'open');
      expect(detail.iid, 7);
      expect(detail.sourceBranch, 'feature');
      expect(detail.targetBranch, 'main');
      expect(detail.webUrl, 'https://github.com/owner/repo/pull/7');
      expect(detail.hasConflicts, isFalse);
      expect(detail.mergeWhenPipelineSucceeds, isFalse);
      expect(detail.author!.username, 'author');
      expect(detail.author!.avatarUrl, 'https://a/me.png');
      expect(detail.diffBaseSha, 'beefdead');
      expect(detail.diffHeadSha, 'deadbeef');

      expect(detail.changes, hasLength(3));
      expect(detail.changes[0].newPath, 'lib/a.dart');
      expect(detail.changes[0].diff, contains('+new'));
      expect(detail.changes[1].newFile, isTrue);
      expect(detail.changes[2].renamedFile, isTrue);
      expect(detail.changes[2].oldPath, 'lib/old.dart');

      expect(detail.comments, hasLength(1));
      expect(detail.comments[0].body, 'looks good');
      expect(detail.comments[0].author!.username, 'reviewer');

      expect(detail.pipelines, hasLength(1));
      expect(detail.pipelines[0].status, 'success');
      expect(detail.pipelines[0].refName, 'feature');
    });

    test('maps merged pull requests to the merged state', () async {
      final mock = MockClient((req) async {
        final path = req.url.queryParameters['path'] ?? '';
        if (path.endsWith('/pulls/9')) {
          return _json(200, {
            'number': 9,
            'title': 'done',
            'state': 'closed',
            'merged': true,
            'merged_at': '2026-01-05T00:00:00Z',
            'html_url': 'https://github.com/o/r/pull/9',
            'head': {'ref': 'f', 'sha': 'a'},
            'base': {'ref': 'main', 'sha': 'b'},
            'user': {'login': 'x'},
          });
        }
        if (req.url.path == '/api/git-connections/github/pipelines') {
          return _json(200, <Object>[]);
        }
        return _json(200, <Object>[]);
      });
      final provider = GitHubMergeRequestProvider(ApiClient.withClient(mock));

      await provider.load('https://github.com/o/r/pull/9');
      expect(provider.value.valueOrNull!.state, 'merged');
    });

    test('maps conflict detection from mergeable', () async {
      final mock = MockClient((req) async {
        final path = req.url.queryParameters['path'] ?? '';
        if (path.endsWith('/pulls/9')) {
          return _json(200, {
            'number': 9,
            'title': 'conflict',
            'state': 'open',
            'mergeable': false,
            'html_url': 'https://github.com/o/r/pull/9',
            'head': {'ref': 'f', 'sha': 'a'},
            'base': {'ref': 'main', 'sha': 'b'},
          });
        }
        return _json(200, <Object>[]);
      });
      final provider = GitHubMergeRequestProvider(ApiClient.withClient(mock));

      await provider.load('https://github.com/o/r/pull/9');
      expect(provider.value.valueOrNull!.hasConflicts, isTrue);
    });

    test('perform posts the action and refreshes', () async {
      String? postedBody;
      final mock = MockClient((req) async {
        if (req.url.path ==
            '/api/git-connections/github/merge-requests/actions') {
          postedBody = req.body;
          return _json(200, {'merged': true});
        }
        final path = req.url.queryParameters['path'] ?? '';
        if (path.endsWith('/pulls/7')) {
          return _json(200, {
            'number': 7,
            'title': 'pr',
            'state': 'closed',
            'html_url': 'https://github.com/o/r/pull/7',
            'head': {'ref': 'f', 'sha': 'a'},
            'base': {'ref': 'main', 'sha': 'b'},
          });
        }
        return _json(200, <Object>[]);
      });
      final provider = GitHubMergeRequestProvider(ApiClient.withClient(mock));
      await provider.load('https://github.com/o/r/pull/7');

      await provider.perform(MergeRequestAction.merge);

      final body = jsonDecode(postedBody!) as Map<String, dynamic>;
      expect(body['project'], 'o/r');
      expect(body['iid'], 7);
      expect(body['hostname'], 'github.com');
      expect(body['action'], 'merge');
      expect(provider.value.valueOrNull!.state, 'closed');
    });

    test('loads jobs and job logs through the github endpoints', () async {
      final mock = MockClient((req) async {
        final path = req.url.queryParameters['path'] ?? '';
        if (path.endsWith('/pulls/7')) {
          return _json(200, {
            'number': 7,
            'title': 'pr',
            'state': 'open',
            'html_url': 'https://github.com/o/r/pull/7',
            'head': {'ref': 'f', 'sha': 'a'},
            'base': {'ref': 'main', 'sha': 'b'},
          });
        }
        if (req.url.path == '/api/git-connections/github/pipelines/jobs') {
          return _json(200, [
            {
              'id': 11,
              'name': 'test',
              'status': 'running',
              'stage': 'CI',
              'web_url': 'https://github.com/o/r/job/11',
            },
          ]);
        }
        if (req.url.path ==
            '/api/git-connections/github/pipelines/jobs/logs') {
          return _json(200, {
            'job': {'id': 11, 'name': 'test', 'status': 'running'},
            'trace': 'log output',
          });
        }
        return _json(200, <Object>[]);
      });
      final provider = GitHubMergeRequestProvider(ApiClient.withClient(mock));
      await provider.load('https://github.com/o/r/pull/7');

      final jobs = await provider.loadJobs(
        const MergeRequestPipeline(id: 1, status: 'running'),
      );
      expect(jobs, hasLength(1));
      expect(jobs[0].status, 'running');
      expect(jobs[0].stage, 'CI');

      final log = await provider.loadJobLog(jobs[0]);
      expect(log.trace, 'log output');
      expect(log.job.id, 11);
    });

    test('loads repository files as decoded bytes', () async {
      final bytes = utf8.encode('hello image');
      final mock = MockClient((req) async {
        final path = req.url.queryParameters['path'] ?? '';
        if (path.endsWith('/pulls/7')) {
          return _json(200, {
            'number': 7,
            'title': 'pr',
            'state': 'open',
            'head': {'ref': 'f', 'sha': 'a'},
            'base': {'ref': 'main', 'sha': 'b'},
          });
        }
        if (path.startsWith('repos/o/r/contents/')) {
          return _json(200, {
            'content': base64Encode(bytes),
            'encoding': 'base64',
            'size': bytes.length,
          });
        }
        return _json(200, <Object>[]);
      });
      final provider = GitHubMergeRequestProvider(ApiClient.withClient(mock));
      await provider.load('https://github.com/o/r/pull/7');

      final data = await provider.loadFile('img/a.png', 'deadbeef');
      expect(data, isA<Uint8List>());
      expect(utf8.decode(data!), 'hello image');
    });

    test('emits an error for non-pull-request URLs', () async {
      final provider = GitHubMergeRequestProvider(
        ApiClient.withClient(MockClient((_) async => _json(200, {}))),
      );
      await provider.load('https://gitlab.com/g/p/-/merge_requests/1');
      expect(provider.value.isError, isTrue);
      expect(
        provider.value.errorOrNull.toString(),
        contains('Not a supported GitHub pull request URL'),
      );
    });
  });
}
