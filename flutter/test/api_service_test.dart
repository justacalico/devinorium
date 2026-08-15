import 'dart:convert';
import 'dart:typed_data';

import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/api/api_service.dart';
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

ApiService _serviceFor(MockClient mock) => ApiService(client: ApiClient.withClient(mock));

Matcher _requestTo(String method, String path) {
  return predicate<http.BaseRequest>((req) => req.method == method && req.url.path == path,
      'a $method request to $path');
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
        return _json(200, {'ok': true, 'totp_required': false, 'username': 'owner'});
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
        return _json(200, {
          'id': 1,
          'username': 'owner',
          'role': 'user',
          'totp_enabled': false,
          'provider_id': 'devin-cli',
          'provider_command': 'devin-cli',
        });
      });
      final service = _serviceFor(mock);
      final user = await service.updateMe(providerId: 'devin-cli', providerCommand: 'devin-cli');
      expect(user.providerCommand, 'devin-cli');
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
          {'id': 1, 'name': 'p', 'path': '/x', 'created_at': '', 'updated_at': ''},
        ]);
      });
      final service = _serviceFor(mock);
      final projects = await service.listProjects();
      expect(projects, hasLength(1));
      expect(projects.first.name, 'p');
    });

    test('createProject sends name and path', () async {
      final mock = MockClient((req) async {
        expect(req, _requestTo('POST', '/api/projects'));
        final body = jsonDecode(_readBody(req)!);
        expect(body['name'], 'p');
        expect(body['path'], '/x');
        return _json(200, {'id': 1, 'name': 'p', 'path': '/x', 'created_at': '', 'updated_at': ''});
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
        expect(body['model'], 'm');
        expect(body['permission_mode'], 'normal');
        expect(body['permissions'], 'perm');
        return _json(200, {
          'id': 'a',
          'title': 't',
          'project_id': 1,
          'model': 'm',
          'permission_mode': 'normal',
          'created_at': '',
          'updated_at': '',
        });
      });
      final service = _serviceFor(mock);
      final t = await service.createThread(
        projectId: 1,
        title: 't',
        threadGroupId: 2,
        model: 'm',
        permissionMode: 'normal',
        permissions: 'perm',
      );
      expect(t.id, 'a');
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
          'messages': [],
        });
      });
      final service = _serviceFor(mock);
      final d = await service.getThread('a');
      expect(d.thread.id, 'a');
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

    test('updateThreadSettings sends non-empty model', () async {
      final mock = MockClient((req) async {
        expect(req, _requestTo('PATCH', '/api/threads/a'));
        final body = jsonDecode(_readBody(req)!);
        expect(body['model'], 'm');
        expect(body['permission_mode'], 'normal');
        return _json(200, {});
      });
      final service = _serviceFor(mock);
      await service.updateThreadSettings('a', model: 'm', permissionMode: 'normal');
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
        return _json(200, {'id': 1, 'name': 'g', 'position': 0, 'created_at': ''});
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
}
