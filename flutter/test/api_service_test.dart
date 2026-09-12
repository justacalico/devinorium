import 'dart:convert';
import 'dart:typed_data';

import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/api/api_service.dart';
import 'package:devinorium_frontend/models/models.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';

http.Response _json(int status, Object body) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

String? _readBody(http.BaseRequest req) {
  if (req is http.Request) return req.body;
  return null;
}

ApiService _serviceFor(MockClient mock) =>
    ApiService(client: ApiClient.withClient(mock));

Matcher _requestTo(String method, String path) {
  return predicate<http.BaseRequest>(
    (req) => req.method == method && req.url.path == path,
    'a $method request to $path',
  );
}

void main() {
  group('Auth', () {
    test('me returns User', () async {
      final mock = MockClient((req) async {
        expect(req, _requestTo('GET', '/api/auth/me'));
        return _json(200, {
          'id': 1,
          'username': 'owner',
          'role': 'user',
          'totp_enabled': false,
          'provider_id': 'devin-cli',
          'provider_command': 'devin',
        });
      });
      final service = _serviceFor(mock);
      final user = await service.me();
      expect(user.username, 'owner');
      expect(user.role, 'user');
    });

    test('login sends body and returns LoginResponse', () async {
      final mock = MockClient((req) async {
        expect(req, _requestTo('POST', '/api/auth/login'));
        final body = jsonDecode(_readBody(req)!);
        expect(body['username'], 'owner');
        expect(body['password'], 'pw');
        return _json(200, {
          'ok': true,
          'totp_required': false,
          'username': 'owner',
        });
      });
      final service = _serviceFor(mock);
      final res = await service.login(username: 'owner', password: 'pw');
      expect(res.ok, isTrue);
      expect(res.username, 'owner');
    });

    test('login includes totp when provided', () async {
      final mock = MockClient((req) async {
        final body = jsonDecode(_readBody(req)!);
        expect(body['totp'], '123456');
        return _json(200, {'ok': true});
      });
      final service = _serviceFor(mock);
      await service.login(username: 'owner', password: 'pw', totp: '123456');
    });

    test('logout sends post', () async {
      final mock = MockClient((req) async {
        expect(req, _requestTo('POST', '/api/auth/logout'));
        return _json(200, {});
      });
      final service = _serviceFor(mock);
      await service.logout();
    });

    test('totpSetup returns TotpSetupResponse', () async {
      final mock = MockClient((req) async {
        expect(req, _requestTo('POST', '/api/auth/totp/setup'));
        return _json(200, {'secret': 's', 'otpauth_uri': 'otpauth://x'});
      });
      final service = _serviceFor(mock);
      final res = await service.totpSetup();
      expect(res.secret, 's');
    });

    test('totpVerify sends code', () async {
      final mock = MockClient((req) async {
        expect(req, _requestTo('POST', '/api/auth/totp/verify'));
        final body = jsonDecode(_readBody(req)!);
        expect(body['code'], '123456');
        return _json(200, {});
      });
      final service = _serviceFor(mock);
      await service.totpVerify('123456');
    });

    test('totpDisable posts', () async {
      final mock = MockClient((req) async {
        expect(req, _requestTo('POST', '/api/auth/totp/disable'));
        return _json(200, {});
      });
      final service = _serviceFor(mock);
      await service.totpDisable();
    });

    test('updateMe sends provider settings and returns User', () async {
      final mock = MockClient((req) async {
        expect(req, _requestTo('PATCH', '/api/auth/me'));
        final body = jsonDecode(_readBody(req)!);
        expect(body['provider_id'], 'devin-cli');
        expect(body['provider_command'], 'devin-cli');
        expect(body['provider_commands'], {'opencode': '/opt/oc'});
        return _json(200, {
          'id': 1,
          'username': 'owner',
          'role': 'user',
          'totp_enabled': false,
          'provider_id': 'devin-cli',
          'provider_command': 'devin-cli',
          'provider_commands': {'opencode': '/opt/oc'},
        });
      });
      final service = _serviceFor(mock);
      final user = await service.updateMe(
        providerId: 'devin-cli',
        providerCommand: 'devin-cli',
        providerCommands: {'opencode': '/opt/oc'},
      );
      expect(user.providerCommand, 'devin-cli');
      expect(user.providerCommands['opencode'], '/opt/oc');
    });

    test('testProvider posts health', () async {
      final mock = MockClient((req) async {
        expect(req, _requestTo('POST', '/api/providers/health'));
        final body = jsonDecode(_readBody(req)!);
        expect(body['provider_id'], 'devin-cli');
        expect(body['command'], 'devin');
        return _json(200, {'ok': true});
      });
      final service = _serviceFor(mock);
      await service.testProvider(providerId: 'devin-cli', command: 'devin');
    });
  });

  group('Projects', () {
    test('listProjects returns projects', () async {
      final mock = MockClient((req) async {
        expect(req, _requestTo('GET', '/api/projects'));
        return _json(200, [
          {
            'id': 1,
            'name': 'p',
            'path': '/x',
            'created_at': '',
            'updated_at': '',
          },
        ]);
      });
      final service = _serviceFor(mock);
      final projects = await service.listProjects();
      expect(projects, hasLength(1));
      expect(projects.first.name, 'p');
    });

    test('listProjects encodes pagination params', () async {
      final mock = MockClient((req) async {
        expect(req.method, 'GET');
        expect(req.url.path, '/api/projects');
        final q = req.url.queryParameters;
        expect(q['limit'], '50');
        expect(q['offset'], '10');
        return _json(200, []);
      });
      final service = _serviceFor(mock);
      final projects = await service.listProjects(limit: 50, offset: 10);
      expect(projects, isEmpty);
    });

    test('createProject sends name and path', () async {
      final mock = MockClient((req) async {
        expect(req, _requestTo('POST', '/api/projects'));
        final body = jsonDecode(_readBody(req)!);
        expect(body['name'], 'p');
        expect(body['path'], '/x');
        return _json(200, {
          'id': 1,
          'name': 'p',
          'path': '/x',
          'created_at': '',
          'updated_at': '',
        });
      });
      final service = _serviceFor(mock);
      final p = await service.createProject(name: 'p', path: '/x');
      expect(p.id, 1);
    });

    test('deleteProject calls delete', () async {
      final mock = MockClient((req) async {
        expect(req, _requestTo('DELETE', '/api/projects/1'));
        return _json(200, {});
      });
      final service = _serviceFor(mock);
      await service.deleteProject(1);
    });

    test('checkHealth returns true on 200', () async {
      final mock = MockClient((req) async {
        expect(req, _requestTo('GET', '/healthz'));
        return _json(200, {'status': 'ok'});
      });
      final service = _serviceFor(mock);
      expect(await service.checkHealth(), isTrue);
    });

    test('checkHealth returns false on error', () async {
      final mock = MockClient((req) async {
        return http.Response('', 500);
      });
      final service = _serviceFor(mock);
      expect(await service.checkHealth(), isFalse);
    });

    test('serverVersion returns version on 200', () async {
      final mock = MockClient((req) async {
        expect(req, _requestTo('GET', '/api/server/version'));
        return _json(200, {'version': '0.31.0'});
      });
      final service = _serviceFor(mock);
      expect(await service.serverVersion(), '0.31.0');
    });

    test('serverVersion returns null on error', () async {
      final mock = MockClient((req) async {
        return http.Response('', 500);
      });
      final service = _serviceFor(mock);
      expect(await service.serverVersion(), isNull);
    });

    test('serverVersion returns null when version field is missing', () async {
      final mock = MockClient((req) async {
        return _json(200, {'other': 'x'});
      });
      final service = _serviceFor(mock);
      expect(await service.serverVersion(), isNull);
    });

    test('serverVersion returns null for non-string version', () async {
      final mock = MockClient((req) async {
        return _json(200, {'version': 123});
      });
      final service = _serviceFor(mock);
      expect(await service.serverVersion(), isNull);
    });

    test('reorderProjects patches project_ids', () async {
      final mock = MockClient((req) async {
        expect(req, _requestTo('PATCH', '/api/projects/reorder'));
        final body = jsonDecode(_readBody(req)!);
        expect(body['project_ids'], [3, 1, 2]);
        return _json(200, {});
      });
      final service = _serviceFor(mock);
      await service.reorderProjects([3, 1, 2]);
    });

    test('renameProject patches name and returns project', () async {
      final mock = MockClient((req) async {
        expect(req, _requestTo('PATCH', '/api/projects/1'));
        final body = jsonDecode(_readBody(req)!);
        expect(body['name'], 'new');
        return _json(200, {
          'id': 1,
          'name': 'new',
          'path': '/x',
          'created_at': '',
          'updated_at': '',
        });
      });
      final service = _serviceFor(mock);
      final p = await service.renameProject(1, 'new');
      expect(p.name, 'new');
      expect(p.id, 1);
    });

    test('pinProject posts pinned and returns project', () async {
      final mock = MockClient((req) async {
        expect(req, _requestTo('POST', '/api/projects/1/pin'));
        final body = jsonDecode(_readBody(req)!);
        expect(body['pinned'], isTrue);
        return _json(200, {
          'id': 1,
          'name': 'p',
          'path': '/x',
          'pinned': true,
          'created_at': '',
          'updated_at': '',
        });
      });
      final service = _serviceFor(mock);
      final p = await service.pinProject(1, true);
      expect(p.pinned, isTrue);
      expect(p.id, 1);
    });

    test('listThreadsForProject uses project id', () async {
      final mock = MockClient((req) async {
        expect(req, _requestTo('GET', '/api/projects/1/threads'));
        return _json(200, []);
      });
      final service = _serviceFor(mock);
      final threads = await service.listThreadsForProject(1);
      expect(threads, isEmpty);
    });
  });

  group('Threads', () {
    test('listThreads returns threads', () async {
      final mock = MockClient((req) async {
        expect(req, _requestTo('GET', '/api/threads'));
        return _json(200, [
          {
            'id': 'a',
            'title': 't',
            'project_id': 1,
            'model': 'm',
            'permission_mode': 'normal',
            'created_at': '',
            'updated_at': '',
          },
        ]);
      });
      final service = _serviceFor(mock);
      final threads = await service.listThreads();
      expect(threads, hasLength(1));
      expect(threads.first.id, 'a');
    });

    test('createThread builds body with optional fields', () async {
      final mock = MockClient((req) async {
        expect(req, _requestTo('POST', '/api/threads'));
        final body = jsonDecode(_readBody(req)!);
        expect(body['project_id'], 1);
        expect(body['title'], 't');
        expect(body['thread_group_id'], 2);
        expect(body['provider'], 'opencode');
        expect(body['model'], 'm');
        expect(body['permission_mode'], 'normal');
        expect(body['reasoning_effort'], 'high');
        expect(body['permissions'], 'perm');
        return _json(200, {
          'id': 'a',
          'title': 't',
          'project_id': 1,
          'model': 'm',
          'permission_mode': 'normal',
          'reasoning_effort': 'high',
          'created_at': '',
          'updated_at': '',
        });
      });
      final service = _serviceFor(mock);
      final t = await service.createThread(
        projectId: 1,
        title: 't',
        threadGroupId: 2,
        provider: 'opencode',
        model: 'm',
        permissionMode: 'normal',
        reasoningEffort: 'high',
        permissions: 'perm',
      );
      expect(t.id, 'a');
      expect(t.reasoningEffort, 'high');
    });

    test('createThread omits absent optional fields', () async {
      final mock = MockClient((req) async {
        final body = jsonDecode(_readBody(req)!);
        expect(body.containsKey('title'), isFalse);
        return _json(200, {
          'id': 'a',
          'title': 't',
          'project_id': 1,
          'model': '',
          'permission_mode': 'normal',
          'created_at': '',
          'updated_at': '',
        });
      });
      final service = _serviceFor(mock);
      await service.createThread(projectId: 1);
    });

    test('getThread returns ThreadDetail', () async {
      final mock = MockClient((req) async {
        expect(req, _requestTo('GET', '/api/threads/a'));
        return _json(200, {
          'thread': {
            'id': 'a',
            'title': 't',
            'project_id': 1,
            'model': '',
            'permission_mode': 'normal',
            'created_at': '',
            'updated_at': '',
          },
          'total_messages': 1,
          'messages': [],
        });
      });
      final service = _serviceFor(mock);
      final d = await service.getThread('a');
      expect(d.thread.id, 'a');
      expect(d.messages, isEmpty);
      expect(d.totalMessages, 1);
    });

    test('getThreadMessages fetches a page', () async {
      final mock = MockClient((req) async {
        expect(req, _requestTo('GET', '/api/threads/a/messages'));
        return _json(200, {
          'messages': [
            {'id': 1, 'role': 'user', 'content': 'hello'},
          ],
          'total': 1,
        });
      });
      final service = _serviceFor(mock);
      final page = await service.getThreadMessages('a');
      expect(page.messages.length, 1);
      expect(page.messages.first.id, 1);
      expect(page.total, 1);
    });

    test('getThreadMessages encodes beforeId, afterId and limit', () async {
      final mock = MockClient((req) async {
        expect(req.method, 'GET');
        expect(req.url.path, '/api/threads/a/messages');
        final q = req.url.queryParameters;
        expect(q['before_id'], '10');
        expect(q['after_id'], '5');
        expect(q['limit'], '25');
        return _json(200, {'messages': [], 'total': 0});
      });
      final service = _serviceFor(mock);
      await service.getThreadMessages('a', beforeId: 10, afterId: 5, limit: 25);
    });

    test('getThreadMessages uses turn-windowed params', () async {
      final mock = MockClient((req) async {
        expect(req.method, 'GET');
        expect(req.url.path, '/api/threads/a/messages');
        final q = req.url.queryParameters;
        expect(q['turn_limit'], '50');
        expect(q['before_cursor'], 'c1');
        expect(q.containsKey('before_id'), isFalse);
        expect(q.containsKey('after_id'), isFalse);
        expect(q.containsKey('limit'), isFalse);
        return _json(200, {
          'messages': [
            {'id': 1, 'role': 'user', 'content': 'hi'},
          ],
          'total': 1,
          'turn_limit': 50,
          'raw_count': 1,
          'before_cursor': 'c0',
          'has_more': false,
        });
      });
      final service = _serviceFor(mock);
      final page = await service.getThreadMessages(
        'a',
        beforeCursor: 'c1',
        turnLimit: 50,
      );
      expect(page.messages, hasLength(1));
      expect(page.turnLimit, 50);
      expect(page.rawCount, 1);
      expect(page.beforeCursor, 'c0');
      expect(page.hasMore, isFalse);
    });

    test('getMessageFull fetches full message', () async {
      final mock = MockClient((req) async {
        expect(req, _requestTo('GET', '/api/threads/a/messages/1/full'));
        return _json(200, {
          'message': {
            'id': 1,
            'role': 'assistant',
            'content': 'full content',
            'truncated': false,
            'total_chars': 12,
          },
        });
      });
      final service = _serviceFor(mock);
      final msg = await service.getMessageFull('a', 1);
      expect(msg.id, 1);
      expect(msg.content, 'full content');
      expect(msg.truncated, isFalse);
      expect(msg.totalChars, 12);
    });

    test('getMessageChunk encodes offset and limit', () async {
      final mock = MockClient((req) async {
        expect(req.method, 'GET');
        expect(req.url.path, '/api/threads/a/messages/1');
        final q = req.url.queryParameters;
        expect(q['offset'], '100');
        expect(q['limit'], '500');
        return _json(200, {
          'message': {'id': 1, 'role': 'assistant', 'content': 'chunk'},
        });
      });
      final service = _serviceFor(mock);
      final msg = await service.getMessageChunk(
        'a',
        1,
        offset: 100,
        limit: 500,
      );
      expect(msg.content, 'chunk');
    });

    test('getThread includeMessages encodes turn_limit', () async {
      final mock = MockClient((req) async {
        expect(req.method, 'GET');
        expect(req.url.path, '/api/threads/a');
        final q = req.url.queryParameters;
        expect(q['include_messages'], '1');
        expect(q['turn_limit'], '50');
        return _json(200, {
          'thread': {
            'id': 'a',
            'title': 't',
            'project_id': 1,
            'model': '',
            'permission_mode': 'normal',
            'created_at': '',
            'updated_at': '',
          },
          'total_messages': 1,
          'messages': [
            {'id': 1, 'role': 'user', 'content': 'hello'},
          ],
          'turn_limit': 50,
          'before_cursor': 'c1',
          'has_more': false,
        });
      });
      final service = _serviceFor(mock);
      final d = await service.getThread(
        'a',
        includeMessages: true,
        turnLimit: 50,
      );
      expect(d.messages, hasLength(1));
      expect(d.turnLimit, 50);
      expect(d.beforeCursor, 'c1');
      expect(d.hasMore, isFalse);
    });

    test('getThread reuses inline messages when present', () async {
      final mock = MockClient((req) async {
        expect(req, _requestTo('GET', '/api/threads/a'));
        return _json(200, {
          'thread': {
            'id': 'a',
            'title': 't',
            'project_id': 1,
            'model': '',
            'permission_mode': 'normal',
            'created_at': '',
            'updated_at': '',
          },
          'total_messages': 1,
          'messages': [
            {'id': 1, 'role': 'user', 'content': 'hello'},
          ],
        });
      });
      final service = _serviceFor(mock);
      final d = await service.getThread('a');
      expect(d.messages.length, 1);
      expect(d.messages.first.id, 1);
    });

    test('getThread includeMessages adds query parameter', () async {
      final mock = MockClient((req) async {
        expect(req.method, 'GET');
        expect(req.url.path, '/api/threads/a');
        expect(req.url.queryParameters['include_messages'], '1');
        return _json(200, {
          'thread': {
            'id': 'a',
            'title': 't',
            'project_id': 1,
            'model': '',
            'permission_mode': 'normal',
            'created_at': '',
            'updated_at': '',
          },
          'total_messages': 1,
          'messages': [
            {'id': 1, 'role': 'user', 'content': 'hello'},
          ],
        });
      });
      final service = _serviceFor(mock);
      final d = await service.getThread('a', includeMessages: true);
      expect(d.messages.length, 1);
      expect(d.messages.first.id, 1);
    });

    test('getThreadRun fetches run status', () async {
      final mock = MockClient((req) async {
        expect(req, _requestTo('GET', '/api/threads/a/run'));
        return _json(200, {
          'run_id': 'r1',
          'thread_id': 'a',
          'status': 'running',
          'started_at': '2024-01-01T00:00:00Z',
          'updated_at': '2024-01-01T00:00:00Z',
          'error': null,
        });
      });
      final service = _serviceFor(mock);
      final run = await service.getThreadRun('a');
      expect(run['status'], 'running');
    });

    test('getThreadRuns returns running ids', () async {
      final mock = MockClient((req) async {
        expect(req, _requestTo('GET', '/api/threads/runs'));
        return _json(200, {
          'running_ids': ['a', 'b'],
        });
      });
      final service = _serviceFor(mock);
      final ids = await service.getThreadRuns();
      expect(ids, ['a', 'b']);
    });

    test('renameThread patches title', () async {
      final mock = MockClient((req) async {
        expect(req, _requestTo('PATCH', '/api/threads/a'));
        final body = jsonDecode(_readBody(req)!);
        expect(body['title'], 'new');
        return _json(200, {});
      });
      final service = _serviceFor(mock);
      await service.renameThread('a', 'new');
    });

    test('pinThread posts pinned and returns thread', () async {
      final mock = MockClient((req) async {
        expect(req, _requestTo('POST', '/api/threads/a/pin'));
        final body = jsonDecode(_readBody(req)!);
        expect(body['pinned'], isTrue);
        return _json(200, {
          'id': 'a',
          'title': 't',
          'project_id': 1,
          'model': '',
          'permission_mode': 'normal',
          'pinned': true,
          'created_at': '',
          'updated_at': '',
        });
      });
      final service = _serviceFor(mock);
      final t = await service.pinThread('a', true);
      expect(t.pinned, isTrue);
      expect(t.id, 'a');
    });

    test('updateThreadSettings sends non-empty model', () async {
      final mock = MockClient((req) async {
        expect(req, _requestTo('PATCH', '/api/threads/a'));
        final body = jsonDecode(_readBody(req)!);
        expect(body['model'], 'm');
        expect(body['permission_mode'], 'normal');
        expect(body['provider'], 'opencode');
        expect(body['reasoning_effort'], 'medium');
        return _json(200, {});
      });
      final service = _serviceFor(mock);
      await service.updateThreadSettings(
        'a',
        provider: 'opencode',
        model: 'm',
        permissionMode: 'normal',
        reasoningEffort: 'medium',
      );
    });

    test('updateThreadSettings clears permissions when empty', () async {
      final mock = MockClient((req) async {
        final body = jsonDecode(_readBody(req)!);
        expect(body['permissions'], isNull);
        return _json(200, {});
      });
      final service = _serviceFor(mock);
      await service.updateThreadSettings('a', permissions: '');
    });

    test('respondPermission sends option_id', () async {
      final mock = MockClient((req) async {
        expect(req, _requestTo('POST', '/api/threads/a/permission/r'));
        final body = jsonDecode(_readBody(req)!);
        expect(body['option_id'], 'allow');
        return _json(200, {});
      });
      final service = _serviceFor(mock);
      await service.respondPermission('a', 'r', 'allow');
    });

    test('moveThreadToGroup sends null for ungroup', () async {
      final mock = MockClient((req) async {
        expect(req, _requestTo('PATCH', '/api/threads/a'));
        final body = jsonDecode(_readBody(req)!);
        expect(body['thread_group_id'], isNull);
        return _json(200, {});
      });
      final service = _serviceFor(mock);
      await service.moveThreadToGroup('a', null);
    });

    test('deleteThread deletes', () async {
      final mock = MockClient((req) async {
        expect(req, _requestTo('DELETE', '/api/threads/a'));
        return _json(200, {});
      });
      final service = _serviceFor(mock);
      await service.deleteThread('a');
    });
  });

  group('Thread Groups', () {
    test('listThreadGroups returns groups', () async {
      final mock = MockClient((req) async {
        expect(req, _requestTo('GET', '/api/thread-groups'));
        return _json(200, []);
      });
      final service = _serviceFor(mock);
      final groups = await service.listThreadGroups();
      expect(groups, isEmpty);
    });

    test('createThreadGroup sends name and thread ids', () async {
      final mock = MockClient((req) async {
        expect(req, _requestTo('POST', '/api/thread-groups'));
        final body = jsonDecode(_readBody(req)!);
        expect(body['name'], 'g');
        expect(body['thread_ids'], ['a']);
        return _json(200, {
          'id': 1,
          'name': 'g',
          'position': 0,
          'created_at': '',
        });
      });
      final service = _serviceFor(mock);
      final g = await service.createThreadGroup(name: 'g', threadIds: ['a']);
      expect(g.id, 1);
    });

    test('renameThreadGroup patches name', () async {
      final mock = MockClient((req) async {
        expect(req, _requestTo('PATCH', '/api/thread-groups/1'));
        final body = jsonDecode(_readBody(req)!);
        expect(body['name'], 'g');
        return _json(200, {});
      });
      final service = _serviceFor(mock);
      await service.renameThreadGroup(1, 'g');
    });

    test('deleteThreadGroup deletes', () async {
      final mock = MockClient((req) async {
        expect(req, _requestTo('DELETE', '/api/thread-groups/1'));
        return _json(200, {});
      });
      final service = _serviceFor(mock);
      await service.deleteThreadGroup(1);
    });
  });

  group('Models and Providers', () {
    test('listModels returns models', () async {
      final mock = MockClient((req) async {
        expect(req, _requestTo('GET', '/api/models'));
        return _json(200, [
          {'id': 'glm-5-2', 'label': 'GLM'},
        ]);
      });
      final service = _serviceFor(mock);
      final models = await service.listModels();
      expect(models.first.id, 'glm-5-2');
    });

    test('listProviders returns providers', () async {
      final mock = MockClient((req) async {
        expect(req, _requestTo('GET', '/api/providers'));
        return _json(200, [
          {'id': 'devin-cli', 'name': 'Devin CLI'},
        ]);
      });
      final service = _serviceFor(mock);
      final providers = await service.listProviders();
      expect(providers.first.name, 'Devin CLI');
    });

    test('listModels sends provider query param', () async {
      final mock = MockClient((req) async {
        expect(req, _requestTo('GET', '/api/models'));
        expect(req.url.queryParameters['provider'], 'opencode');
        return _json(200, [
          {'id': 'opencode/big-pickle', 'label': 'Big Pickle'},
        ]);
      });
      final service = _serviceFor(mock);
      final models = await service.listModels(provider: 'opencode');
      expect(models.first.id, 'opencode/big-pickle');
    });

    test('providerVersion sends provider query param', () async {
      final mock = MockClient((req) async {
        expect(req, _requestTo('GET', '/api/providers/version'));
        expect(req.url.queryParameters['provider'], 'opencode');
        return _json(200, {
          'provider_id': 'opencode',
          'provider_name': 'OpenCode',
          'installed_version': '1.18.27',
        });
      });
      final service = _serviceFor(mock);
      final v = await service.providerVersion(provider: 'opencode');
      expect(v.providerId, 'opencode');
    });

    test('providerVersion returns version info', () async {
      final mock = MockClient((req) async {
        expect(req, _requestTo('GET', '/api/providers/version'));
        return _json(200, {
          'provider_id': 'devin-cli',
          'provider_name': 'Devin CLI',
          'installed_version': '3000.6.13',
          'latest_version': '3000.6.14',
          'update_available': true,
        });
      });
      final service = _serviceFor(mock);
      final v = await service.providerVersion();
      expect(v.providerId, 'devin-cli');
      expect(v.installedVersion, '3000.6.13');
      expect(v.latestVersion, '3000.6.14');
      expect(v.updateAvailable, isTrue);
    });

    test('providerVersion tolerates null versions', () async {
      final mock = MockClient((req) async {
        return _json(200, {
          'provider_id': 'devin-cli',
          'provider_name': 'Devin CLI',
          'installed_version': null,
          'latest_version': null,
          'update_available': false,
        });
      });
      final service = _serviceFor(mock);
      final v = await service.providerVersion();
      expect(v.installedVersion, isNull);
      expect(v.updateAvailable, isFalse);
    });
  });

  group('Files', () {
    test('listFiles encodes query parameters', () async {
      final mock = MockClient((req) async {
        expect(req.method, 'GET');
        expect(req.url.path, '/api/files');
        expect(req.url.queryParameters['path'], 'foo');
        expect(req.url.queryParameters['project_id'], '1');
        return _json(200, []);
      });
      final service = _serviceFor(mock);
      final files = await service.listFiles(path: 'foo', projectId: 1);
      expect(files, isEmpty);
    });

    test('readFile encodes query parameters and diff flag', () async {
      final mock = MockClient((req) async {
        expect(req.method, 'GET');
        expect(req.url.path, '/api/files/content');
        expect(req.url.queryParameters['path'], 'foo.rs');
        expect(req.url.queryParameters['project_id'], '1');
        expect(req.url.queryParameters['diff'], 'true');
        return _json(200, {
          'path': '/projects/1/foo.rs',
          'mime': 'text/x-rust',
          'size': 12,
          'base64': 'Zm4gbWFpbigpIHt9',
          'text': null,
          'diff': {
            'path': '/projects/1/foo.rs',
            'old_text': null,
            'new_text': 'fn main() {}',
          },
        });
      });
      final service = _serviceFor(mock);
      final content = await service.readFile(
        path: 'foo.rs',
        projectId: 1,
        includeDiff: true,
      );
      expect(content.path, '/projects/1/foo.rs');
      expect(content.text, 'fn main() {}');
      expect(content.diff?.newText, 'fn main() {}');
      expect(content.diff?.oldText, isNull);
    });

    test('writeFile sends body and returns content', () async {
      final mock = MockClient((req) async {
        expect(req, _requestTo('PUT', '/api/files/content'));
        final body = jsonDecode(_readBody(req)!);
        expect(body['path'], 'foo.rs');
        expect(body['content'], 'new text');
        expect(body['project_id'], 1);
        expect(body['expected_sha256'], 'sha');
        return _json(200, {
          'path': '/projects/1/foo.rs',
          'mime': 'text/x-rust',
          'size': 8,
          'base64': '',
          'text': 'new text',
          'sha256': 'sha2',
        });
      });
      final service = _serviceFor(mock);
      final content = await service.writeFile(
        path: 'foo.rs',
        projectId: 1,
        content: 'new text',
        expectedSha256: 'sha',
      );
      expect(content.text, 'new text');
      expect(content.sha256, 'sha2');
    });

    test('writeFile throws FileConflictException on 409', () async {
      final mock = MockClient((req) async {
        return _json(409, {
          'error': 'conflict',
          'current': {
            'path': '/projects/1/foo.rs',
            'mime': 'text/x-rust',
            'size': 4,
            'base64': '',
            'text': 'disk',
            'sha256': 'sha3',
          },
        });
      });
      final service = _serviceFor(mock);
      expect(
        () => service.writeFile(
          path: 'foo.rs',
          projectId: 1,
          content: 'new text',
          expectedSha256: 'sha',
        ),
        throwsA(isA<FileConflictException>()),
      );
    });

    test('mkdir sends path and project_id', () async {
      final mock = MockClient((req) async {
        expect(req, _requestTo('POST', '/api/files/dir'));
        final body = jsonDecode(_readBody(req)!);
        expect(body['path'], 'foo');
        expect(body['project_id'], 1);
        return _json(200, {});
      });
      final service = _serviceFor(mock);
      await service.mkdir('foo', projectId: 1);
    });

    test('deleteFile encodes query parameters', () async {
      final mock = MockClient((req) async {
        expect(req.method, 'DELETE');
        expect(req.url.path, '/api/files/delete');
        expect(req.url.queryParameters['path'], 'foo');
        expect(req.url.queryParameters['project_id'], '1');
        return _json(200, {});
      });
      final service = _serviceFor(mock);
      await service.deleteFile('foo', projectId: 1);
    });

    test('uploadFiles posts multipart', () async {
      final mock = MockClient((req) async {
        expect(req.method, 'POST');
        expect(req.url.path, '/api/files');
        return _json(200, {'ok': true});
      });
      final service = _serviceFor(mock);
      final files = <({String filename, String mime, Uint8List bytes})>[
        (filename: 'a.txt', mime: 'text/plain', bytes: Uint8List.fromList([1])),
      ];
      await service.uploadFiles(destDir: 'dir', projectId: 1, files: files);
    });

    test('listFiles encodes thread_id', () async {
      final mock = MockClient((req) async {
        expect(req.url.queryParameters['project_id'], '1');
        expect(req.url.queryParameters['thread_id'], 't1');
        return _json(200, []);
      });
      final service = _serviceFor(mock);
      await service.listFiles(path: 'foo', projectId: 1, threadId: 't1');
    });

    test('readFile encodes thread_id', () async {
      final mock = MockClient((req) async {
        expect(req.url.queryParameters['project_id'], '1');
        expect(req.url.queryParameters['thread_id'], 't1');
        return _json(200, {
          'path': '/wt/foo.rs',
          'mime': 'text/x-rust',
          'size': 4,
          'base64': '',
          'text': 'hi',
          'sha256': 's',
        });
      });
      final service = _serviceFor(mock);
      await service.readFile(path: 'foo.rs', projectId: 1, threadId: 't1');
    });

    test('writeFile sends thread_id in body', () async {
      final mock = MockClient((req) async {
        final body = jsonDecode(_readBody(req)!);
        expect(body['project_id'], 1);
        expect(body['thread_id'], 't1');
        return _json(200, {
          'path': '/wt/foo.rs',
          'mime': 'text/x-rust',
          'size': 4,
          'base64': '',
          'text': 'hi',
          'sha256': 's',
        });
      });
      final service = _serviceFor(mock);
      await service.writeFile(
        path: 'foo.rs',
        projectId: 1,
        threadId: 't1',
        content: 'hi',
      );
    });

    test('mkdir sends thread_id', () async {
      final mock = MockClient((req) async {
        final body = jsonDecode(_readBody(req)!);
        expect(body['project_id'], 1);
        expect(body['thread_id'], 't1');
        return _json(200, {});
      });
      final service = _serviceFor(mock);
      await service.mkdir('foo', projectId: 1, threadId: 't1');
    });

    test('deleteFile encodes thread_id', () async {
      final mock = MockClient((req) async {
        expect(req.url.queryParameters['project_id'], '1');
        expect(req.url.queryParameters['thread_id'], 't1');
        return _json(200, {});
      });
      final service = _serviceFor(mock);
      await service.deleteFile('foo', projectId: 1, threadId: 't1');
    });
  });

  group('Users', () {
    test('listUsers returns users', () async {
      final mock = MockClient((req) async {
        expect(req, _requestTo('GET', '/api/users'));
        return _json(200, [
          {
            'id': 1,
            'username': 'owner',
            'role': 'user',
            'is_owner': true,
            'disabled': false,
            'totp_enabled': true,
            'created_at': '2026-01-01',
          },
          {
            'id': 2,
            'username': 'alice',
            'role': 'user',
            'is_owner': false,
            'disabled': true,
            'totp_enabled': false,
            'created_at': '2026-01-02',
          },
        ]);
      });
      final service = _serviceFor(mock);
      final users = await service.listUsers();
      expect(users, hasLength(2));
      expect(users.first.isOwner, isTrue);
      expect(users.first.totpEnabled, isTrue);
      expect(users.last.disabled, isTrue);
      expect(users.last.isOwner, isFalse);
    });

    test('createUser sends username and password', () async {
      final mock = MockClient((req) async {
        expect(req, _requestTo('POST', '/api/users'));
        final body = jsonDecode(_readBody(req)!);
        expect(body['username'], 'alice');
        expect(body['password'], 'pw');
        return _json(200, {'ok': true, 'id': 2, 'username': 'alice'});
      });
      final service = _serviceFor(mock);
      await service.createUser(username: 'alice', password: 'pw');
    });

    test('setUserDisabled sends disabled', () async {
      final mock = MockClient((req) async {
        expect(req, _requestTo('PATCH', '/api/users/1'));
        final body = jsonDecode(_readBody(req)!);
        expect(body['disabled'], isTrue);
        return _json(200, {'ok': true});
      });
      final service = _serviceFor(mock);
      await service.setUserDisabled(1, true);
    });
  });

  group('parseSseMessage', () {
    test('decodes user message JSON', () {
      final msg = parseSseMessage('{"role":"user","content":"hi"}');
      expect(msg, isNotNull);
      expect(msg!.role, 'user');
      expect(msg.content, 'hi');
    });

    test('returns null for invalid JSON', () {
      final msg = parseSseMessage('not json');
      expect(msg, isNull);
    });
  });

  group('findMergeRequestForBranch', () {
    test('returns MR on 200', () async {
      final mock = MockClient((req) async {
        expect(req.method, 'GET');
        expect(req.url.path, '/api/projects/3/git/merge-request');
        expect(req.url.queryParameters['branch'], 'feature/x');
        return _json(200, {
          'iid': 12,
          'title': 'Add feature',
          'state': 'opened',
          'source_branch': 'feature/x',
          'target_branch': 'main',
          'web_url': 'https://gitlab.example.com/g/p/-/merge_requests/12',
          'draft': false,
        });
      });
      final service = _serviceFor(mock);
      final mr = await service.findMergeRequestForBranch(3, 'feature/x');
      expect(mr, isNotNull);
      expect(mr!.iid, 12);
      expect(mr.title, 'Add feature');
      expect(mr.sourceBranch, 'feature/x');
      expect(mr.webUrl, 'https://gitlab.example.com/g/p/-/merge_requests/12');
      expect(mr.draft, isFalse);
      expect(mr.isOpen, isTrue);
    });

    test('returns null on 204 no content', () async {
      final mock = MockClient((req) async {
        return http.Response('', 204);
      });
      final service = _serviceFor(mock);
      final mr = await service.findMergeRequestForBranch(3, 'feature/x');
      expect(mr, isNull);
    });

    test('returns null on 404 (no GitLab remote / glab missing)', () async {
      final mock = MockClient((req) async {
        return _json(404, {'error': 'not a gitlab repository'});
      });
      final service = _serviceFor(mock);
      final mr = await service.findMergeRequestForBranch(3, 'feature/x');
      expect(mr, isNull);
    });

    test('rethrows non-404 errors', () async {
      final mock = MockClient((req) async {
        return _json(500, {'error': 'boom'});
      });
      final service = _serviceFor(mock);
      await expectLater(
        service.findMergeRequestForBranch(3, 'feature/x'),
        throwsA(isA<ApiException>()),
      );
    });

    test('short-circuits when branch is empty', () async {
      final mock = MockClient((req) async {
        fail('should not make a request for an empty branch');
      });
      final service = _serviceFor(mock);
      final mr = await service.findMergeRequestForBranch(3, '');
      expect(mr, isNull);
    });
  });

  group('Tailscale', () {
    final statusBody = {
      'local_mode': false,
      'installed': true,
      'backend_state': 'Running',
      'magic_dns_name': 'devbox.tail-abc.ts.net',
      'tailnet_ipv4': ['100.64.1.2'],
      'serve_enabled': false,
      'serve_port': 443,
      'https_url': null,
      'https_reachable': null,
      'endpoints': [
        {
          'kind': 'tailnet-ip',
          'label': 'Tailnet IP',
          'url': 'http://100.64.1.2:7878',
          'reachable': true,
        },
      ],
    };

    test('tailscaleStatus GETs /api/tailscale and parses the info', () async {
      final mock = MockClient((req) async {
        expect(req, _requestTo('GET', '/api/tailscale'));
        return _json(200, statusBody);
      });
      final service = _serviceFor(mock);
      final info = await service.tailscaleStatus();
      expect(info.installed, isTrue);
      expect(info.localMode, isFalse);
      expect(info.magicDnsName, 'devbox.tail-abc.ts.net');
      expect(info.tailnetIpv4, ['100.64.1.2']);
      expect(info.serveEnabled, isFalse);
      expect(info.endpoints.single.url, 'http://100.64.1.2:7878');
      expect(info.endpoints.single.reachable, isTrue);
    });

    test('setTailscaleServe PUTs the toggle and parses the response', () async {
      final mock = MockClient((req) async {
        expect(req, _requestTo('PUT', '/api/tailscale/serve'));
        final body = jsonDecode(_readBody(req)!);
        expect(body['enabled'], isTrue);
        expect(body.containsKey('port'), isFalse);
        return _json(200, {
          ...statusBody,
          'serve_enabled': true,
          'https_url': 'https://devbox.tail-abc.ts.net/',
          'https_reachable': true,
        });
      });
      final service = _serviceFor(mock);
      final info = await service.setTailscaleServe(enabled: true);
      expect(info.serveEnabled, isTrue);
      expect(info.httpsUrl, 'https://devbox.tail-abc.ts.net/');
      expect(info.httpsReachable, isTrue);
    });

    test('setTailscaleServe reports the port the mapping listens on', () async {
      final mock = MockClient((req) async {
        final body = jsonDecode(_readBody(req)!);
        expect(body['enabled'], isTrue);
        return _json(200, {
          ...statusBody,
          'serve_enabled': true,
          'serve_port': 8443,
          'https_url': 'https://devbox.tail-abc.ts.net:8443/',
        });
      });
      final service = _serviceFor(mock);
      final info = await service.setTailscaleServe(enabled: true);
      expect(info.servePort, 8443);
      expect(info.httpsUrl, 'https://devbox.tail-abc.ts.net:8443/');
    });

    test('tailscaleStatus surfaces ApiException on errors', () async {
      final mock = MockClient((req) async {
        return _json(404, {'error': 'tailscale CLI is not installed'});
      });
      final service = _serviceFor(mock);
      await expectLater(
        service.tailscaleStatus(),
        throwsA(isA<ApiException>()),
      );
    });
  });
}
