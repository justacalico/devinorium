import 'dart:async';
import 'dart:convert';

import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/merge_request/gitlab_merge_request_provider.dart';
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
          return _json(200, [
            {
              'id': 42,
              'status': 'success',
              'name': 'test-and-build',
              'web_url': 'https://gitlab.com/group/project/-/pipelines/42',
              'ref_name': 'feature',
              'created_at': '2026-01-01T00:00:00Z',
              'updated_at': '2026-01-02T00:00:00Z',
            },
          ]);
        }

        return _json(404, {'error': 'unexpected'});
      });

      final client = ApiClient.withClient(mock);
      final provider = GitLabMergeRequestProvider(client);
      await provider.load(
        'https://gitlab.com/group/project/-/merge_requests/1',
      );

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
      expect(detail.pipelines.length, 1);
      expect(detail.pipelines.first.id, 42);
      expect(detail.pipelines.first.status, 'success');
      expect(detail.pipelines.first.name, 'test-and-build');
      expect(
        detail.pipelines.first.webUrl,
        'https://gitlab.com/group/project/-/pipelines/42',
      );
      expect(detail.pipelines.first.refName, 'feature');
      expect(detail.pipelines.first.createdAt, '2026-01-01T00:00:00Z');
      expect(detail.pipelines.first.updatedAt, '2026-01-02T00:00:00Z');
    });

    test(
      'loads with no pipeline when endpoint returns an empty list',
      () async {
        final mock = MockClient((req) async {
          if (req.url.path == '/api/git-connections/gitlab/pipelines') {
            return _json(200, []);
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
        await provider.load(
          'https://gitlab.com/group/project/-/merge_requests/1',
        );

        expect(provider.value.isReady, isTrue);
        expect(provider.value.valueOrNull?.pipelines, isEmpty);
      },
    );

    test(
      'loads multiple pipelines and ignores malformed list entries',
      () async {
        final mock = MockClient((req) async {
          if (req.url.path == '/api/git-connections/gitlab/pipelines') {
            return _json(200, [
              {
                'status': 'success',
                'name': 'test-and-build',
                'web_url': 'https://gitlab.com/group/project/-/pipelines/42',
                'ref_name': 'feature',
                'created_at': '2026-01-02T00:00:00Z',
                'updated_at': '2026-01-03T00:00:00Z',
              },
              'malformed',
              {
                'status': 'failed',
                'name': 'lint',
                'web_url': 'https://gitlab.com/group/project/-/pipelines/7',
                'ref_name': 'feature',
                'created_at': '2026-01-01T00:00:00Z',
                'updated_at': '2026-01-02T00:00:00Z',
              },
            ]);
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
        await provider.load(
          'https://gitlab.com/group/project/-/merge_requests/1',
        );

        expect(provider.value.isReady, isTrue);
        final detail = provider.value.valueOrNull!;
        expect(detail.pipelines.length, 2);
        expect(detail.pipelines[0].name, 'test-and-build');
        expect(detail.pipelines[1].name, 'lint');
        expect(detail.pipelines[0].createdAt, '2026-01-02T00:00:00Z');
        expect(detail.pipelines[0].updatedAt, '2026-01-03T00:00:00Z');
      },
    );

    test('performs an action and reloads the merge request', () async {
      final actions = <Map<String, dynamic>>[];
      var state = 'opened';

      final mock = MockClient((req) async {
        if (req.url.path ==
            '/api/git-connections/gitlab/merge-requests/actions') {
          actions.add(jsonDecode(req.body) as Map<String, dynamic>);
          state = 'closed';
          return _json(200, {'iid': 1, 'state': state});
        }

        if (req.url.path == '/api/git-connections/gitlab/pipelines') {
          return _json(200, []);
        }

        final path = req.url.queryParameters['path'] ?? '';
        if (path.endsWith('/merge_requests/1')) {
          return _json(200, {
            'iid': 1,
            'title': 'Add feature',
            'state': state,
            'source_branch': 'feature',
            'target_branch': 'main',
            'web_url': 'https://gitlab.com/group/project/-/merge_requests/1',
            'merge_when_pipeline_succeeds': false,
          });
        }
        return _json(200, {'_list': []});
      });

      final provider = GitLabMergeRequestProvider(ApiClient.withClient(mock));
      await provider.load(
        'https://gitlab.com/group/project/-/merge_requests/1',
      );
      expect(provider.value.valueOrNull?.isOpen, isTrue);

      await provider.perform(MergeRequestAction.close);

      expect(actions, hasLength(1));
      expect(actions.first['project'], 'group/project');
      expect(actions.first['iid'], 1);
      expect(actions.first['hostname'], 'gitlab.com');
      expect(actions.first['action'], 'close');
      expect(provider.value.valueOrNull?.isClosed, isTrue);
    });

    test('sends the host of self-managed instances', () async {
      final actions = <Map<String, dynamic>>[];
      final mock = MockClient((req) async {
        if (req.url.path ==
            '/api/git-connections/gitlab/merge-requests/actions') {
          actions.add(jsonDecode(req.body) as Map<String, dynamic>);
          return _json(200, {'iid': 42});
        }
        if (req.url.path == '/api/git-connections/gitlab/pipelines') {
          return _json(200, []);
        }
        final path = req.url.queryParameters['path'] ?? '';
        if (path.endsWith('/merge_requests/42')) {
          return _json(200, {
            'iid': 42,
            'title': 'Add feature',
            'state': 'opened',
            'source_branch': 'feature',
            'target_branch': 'main',
          });
        }
        return _json(200, {'_list': []});
      });

      final provider = GitLabMergeRequestProvider(ApiClient.withClient(mock));
      await provider.load(
        'https://gitlab.example.com/group/sub/project/-/merge_requests/42',
      );
      await provider.perform(MergeRequestAction.mergeWhenPipelineSucceeds);

      expect(actions.first['hostname'], 'gitlab.example.com');
      expect(actions.first['project'], 'group/sub/project');
      expect(actions.first['iid'], 42);
      expect(actions.first['action'], 'merge_when_pipeline_succeeds');
    });

    test('parses merge_when_pipeline_succeeds', () async {
      final mock = MockClient((req) async {
        if (req.url.path == '/api/git-connections/gitlab/pipelines') {
          return _json(200, []);
        }
        final path = req.url.queryParameters['path'] ?? '';
        if (path.endsWith('/merge_requests/1')) {
          return _json(200, {
            'iid': 1,
            'title': 'Add feature',
            'state': 'opened',
            'source_branch': 'feature',
            'target_branch': 'main',
            'merge_when_pipeline_succeeds': true,
          });
        }
        return _json(200, {'_list': []});
      });

      final provider = GitLabMergeRequestProvider(ApiClient.withClient(mock));
      await provider.load(
        'https://gitlab.com/group/project/-/merge_requests/1',
      );

      expect(provider.value.valueOrNull?.mergeWhenPipelineSucceeds, isTrue);
    });

    test('surfaces action errors and keeps the loaded merge request', () async {
      final mock = MockClient((req) async {
        if (req.url.path ==
            '/api/git-connections/gitlab/merge-requests/actions') {
          return _json(400, {'error': 'Method Not Allowed'});
        }
        if (req.url.path == '/api/git-connections/gitlab/pipelines') {
          return _json(200, []);
        }
        final path = req.url.queryParameters['path'] ?? '';
        if (path.endsWith('/merge_requests/1')) {
          return _json(200, {
            'iid': 1,
            'title': 'Add feature',
            'state': 'opened',
            'source_branch': 'feature',
            'target_branch': 'main',
          });
        }
        return _json(200, {'_list': []});
      });

      final provider = GitLabMergeRequestProvider(ApiClient.withClient(mock));
      await provider.load(
        'https://gitlab.com/group/project/-/merge_requests/1',
      );

      await expectLater(
        provider.perform(MergeRequestAction.merge),
        throwsA(isA<ApiException>()),
      );
      expect(provider.value.isReady, isTrue);
      expect(provider.value.valueOrNull?.isOpen, isTrue);
    });

    test(
      'keeps the merge request when the refresh after an action fails',
      () async {
        var acted = false;
        final mock = MockClient((req) async {
          if (req.url.path ==
              '/api/git-connections/gitlab/merge-requests/actions') {
            acted = true;
            return _json(200, {'iid': 1});
          }
          if (acted) return _json(500, {'error': 'gitlab is down'});

          if (req.url.path == '/api/git-connections/gitlab/pipelines') {
            return _json(200, []);
          }
          final path = req.url.queryParameters['path'] ?? '';
          if (path.endsWith('/merge_requests/1')) {
            return _json(200, {
              'iid': 1,
              'title': 'Add feature',
              'state': 'opened',
              'source_branch': 'feature',
              'target_branch': 'main',
            });
          }
          return _json(200, {'_list': []});
        });

        final provider = GitLabMergeRequestProvider(ApiClient.withClient(mock));
        await provider.load(
          'https://gitlab.com/group/project/-/merge_requests/1',
        );
        await provider.perform(MergeRequestAction.merge);

        expect(provider.value.isReady, isTrue);
        expect(provider.value.valueOrNull?.title, 'Add feature');
      },
    );

    test('does not notify after being disposed', () async {
      final gate = Completer<void>();
      final mock = MockClient((req) async {
        if (req.url.path ==
            '/api/git-connections/gitlab/merge-requests/actions') {
          return _json(200, {'iid': 1});
        }
        if (req.url.path == '/api/git-connections/gitlab/pipelines') {
          await gate.future;
          return _json(200, []);
        }
        final path = req.url.queryParameters['path'] ?? '';
        if (path.endsWith('/merge_requests/1')) {
          return _json(200, {
            'iid': 1,
            'title': 'Add feature',
            'state': 'opened',
            'source_branch': 'feature',
            'target_branch': 'main',
          });
        }
        return _json(200, {'_list': []});
      });

      final provider = GitLabMergeRequestProvider(ApiClient.withClient(mock));
      final loading = provider.load(
        'https://gitlab.com/group/project/-/merge_requests/1',
      );
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

      final mock = MockClient((req) async {
        if (req.url.path == '/api/git-connections/gitlab/pipelines') {
          final iid = int.parse(req.url.queryParameters['iid']!);
          await gates[iid]!.future;
          return _json(200, []);
        }
        final path = req.url.queryParameters['path'] ?? '';
        final iid = path.endsWith('/merge_requests/2') ? 2 : 1;
        if (path.contains('/merge_requests/')) {
          return _json(200, {
            'iid': iid,
            'title': 'MR $iid',
            'state': 'opened',
            'source_branch': 'feature',
            'target_branch': 'main',
          });
        }
        return _json(200, {'_list': []});
      });

      final provider = GitLabMergeRequestProvider(ApiClient.withClient(mock));
      final first = provider.load(
        'https://gitlab.com/group/project/-/merge_requests/1',
      );
      final second = provider.load(
        'https://gitlab.com/group/project/-/merge_requests/2',
      );

      // The newer request finishes first; the stale one must not overwrite it.
      gates[2]!.complete();
      await second;
      gates[1]!.complete();
      await first;

      expect(provider.value.valueOrNull?.iid, 2);
    });

    test('refuses to act before a merge request is loaded', () async {
      final provider = GitLabMergeRequestProvider(
        ApiClient.withClient(MockClient((_) async => _json(200, {}))),
      );

      await expectLater(
        provider.perform(MergeRequestAction.merge),
        throwsA(isA<StateError>()),
      );
    });

    test('loads pipeline jobs', () async {
      final mock = MockClient((req) async {
        final query = req.url.queryParameters;

        if (req.url.path == '/api/git-connections/gitlab/pipelines/jobs') {
          expect(query['project'], 'group/project');
          expect(query['pipeline_id'], '42');
          expect(query['hostname'], 'gitlab.com');
          return _json(200, [
            {
              'id': 101,
              'name': 'cargo test',
              'status': 'running',
              'stage': 'test',
              'web_url': 'https://gitlab.com/-/jobs/101',
              'started_at': '2026-01-01T00:00:00Z',
              'finished_at': '',
              'duration': 0,
            },
            'malformed',
            {
              'id': 102,
              'name': 'flutter test',
              'status': 'success',
              'stage': 'test',
            },
          ]);
        }

        if (req.url.path == '/api/git-connections/gitlab/pipelines') {
          return _json(200, [
            {
              'id': 42,
              'status': 'running',
              'name': 'test-and-build',
              'web_url': 'https://gitlab.com/group/project/-/pipelines/42',
              'ref_name': 'feature',
            },
          ]);
        }

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

        return _json(200, {'_list': []});
      });

      final provider = GitLabMergeRequestProvider(ApiClient.withClient(mock));
      await provider.load(
        'https://gitlab.com/group/project/-/merge_requests/1',
      );

      final pipeline = provider.value.valueOrNull!.pipelines.first;
      final jobs = await provider.loadJobs(pipeline);

      expect(jobs.length, 2);
      expect(jobs[0].id, 101);
      expect(jobs[0].name, 'cargo test');
      expect(jobs[0].status, 'running');
      expect(jobs[1].id, 102);
      expect(jobs[1].name, 'flutter test');
      expect(jobs[1].status, 'success');
    });

    test('throws for loadJobs with an invalid pipeline id', () async {
      final mock = MockClient((req) async {
        if (req.url.path == '/api/git-connections/gitlab/pipelines') {
          return _json(200, []);
        }
        final path = req.url.queryParameters['path'] ?? '';
        if (path.endsWith('/merge_requests/1')) {
          return _json(200, {
            'iid': 1,
            'state': 'opened',
            'source_branch': 'feature',
            'target_branch': 'main',
          });
        }
        return _json(200, {'_list': []});
      });

      final provider = GitLabMergeRequestProvider(ApiClient.withClient(mock));
      await provider.load(
        'https://gitlab.com/group/project/-/merge_requests/1',
      );

      await expectLater(
        provider.loadJobs(const MergeRequestPipeline(id: 0, status: 'running')),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('throws for loadJobs when no merge request is loaded', () async {
      final provider = GitLabMergeRequestProvider(
        ApiClient.withClient(MockClient((_) async => _json(200, {}))),
      );

      await expectLater(
        provider.loadJobs(const MergeRequestPipeline(id: 1, status: 'running')),
        throwsA(isA<StateError>()),
      );
    });

    test('surfaces loadJobs backend errors', () async {
      final mock = MockClient((req) async {
        if (req.url.path == '/api/git-connections/gitlab/pipelines/jobs') {
          return _json(500, {'error': 'gitlab is down'});
        }
        if (req.url.path == '/api/git-connections/gitlab/pipelines') {
          return _json(200, []);
        }
        final path = req.url.queryParameters['path'] ?? '';
        if (path.endsWith('/merge_requests/1')) {
          return _json(200, {
            'iid': 1,
            'state': 'opened',
            'source_branch': 'feature',
            'target_branch': 'main',
          });
        }
        return _json(200, {'_list': []});
      });

      final provider = GitLabMergeRequestProvider(ApiClient.withClient(mock));
      await provider.load(
        'https://gitlab.com/group/project/-/merge_requests/1',
      );

      await expectLater(
        provider.loadJobs(const MergeRequestPipeline(id: 1, status: 'running')),
        throwsA(isA<ApiException>()),
      );
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
