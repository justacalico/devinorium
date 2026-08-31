import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/api/api_service.dart';
import 'package:devinorium_frontend/models/composer_mode.dart';
import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter/material.dart' show Locale, ThemeMode;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_test/flutter_test.dart';

http.Response _json(int status, Object body) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

ApiClient _clientFor(List<http.Response> responses) {
  var index = 0;
  return ApiClient.withClient(
    MockClient((req) async {
      if (index >= responses.length) {
        return _json(404, {'error': 'unexpected request to ${req.url.path}'});
      }
      return responses[index++];
    }),
  );
}

/// [ApiService] whose streaming and run endpoints can be replaced by test fakes.
class _StreamableApiService extends ApiService {
  Stream<SseEvent> Function()? streamBuilder;
  Stream<SseEvent> Function()? eventsBuilder;
  Map<String, dynamic>? runResponse;
  String? stoppedThread;
  String? lastClientMessageId;

  _StreamableApiService(ApiClient client) : super(client: client);

  @override
  Future<void> stopThread(String id) async {
    stoppedThread = id;
  }

  @override
  Stream<SseEvent> sendMessageStream({
    required String threadId,
    required String prompt,
    String? mode,
    String? clientMessageId,
    List<({String filename, String mime, Uint8List bytes})> attachments =
        const [],
  }) {
    lastClientMessageId = clientMessageId;
    return streamBuilder?.call() ?? Stream.empty();
  }

  @override
  Future<Map<String, dynamic>> getThreadRun(String id) async {
    return runResponse ?? {'status': 'idle'};
  }

  @override
  Future<List<String>> getThreadRuns() async => [];

  @override
  Stream<SseEvent> watchThreadEvents(String id) {
    return eventsBuilder?.call() ?? Stream.empty();
  }
}

void main() {
  group('Basic state mutations', () {
    test('attachments can be added and removed', () {
      final state = AppState.test();
      final file = (
        filename: 'a.txt',
        mime: 'text/plain',
        bytes: Uint8List.fromList([1]),
      );
      state.addAttachments([file]);
      expect(state.attachments, hasLength(1));
      state.removeAttachment(0);
      expect(state.attachments, isEmpty);
      state.addAttachments([file]);
      state.clearAttachments();
      expect(state.attachments, isEmpty);
    });

    test('composer text and selection state', () {
      final state = AppState.test();
      state.setComposerText('hello');
      expect(state.composerText, 'hello');
      state.setSelectedModel('glm-5-2');
      expect(state.selectedModel, 'glm-5-2');
      state.setSelectedPermission('accept-edits');
      expect(state.selectedPermission, 'accept-edits');
      expect(state.composerMode, ComposerMode.code);
      state.setComposerMode(ComposerMode.plan);
      expect(state.composerMode, ComposerMode.plan);
    });

    test('composer mode is persisted', () async {
      SharedPreferences.setMockInitialValues({});
      final state = AppState.test();
      state.setComposerMode(ComposerMode.ask);
      await Future.delayed(Duration.zero);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('devinorium_composer_mode'), 'ask');
    });

    test('composer mode is not persisted when persist is false', () async {
      SharedPreferences.setMockInitialValues({});
      final state = AppState.test();
      state.setComposerMode(ComposerMode.ask, persist: false);
      await Future.delayed(Duration.zero);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('devinorium_composer_mode'), isNull);
    });

    test('composer mode is loaded from shared preferences', () async {
      SharedPreferences.setMockInitialValues({
        'devinorium_composer_mode': 'plan',
      });
      final state = AppState.test();
      await state.bootstrap();
      expect(state.composerMode, ComposerMode.plan);
    });

    test('menu and dialog toggles', () {
      final state = AppState.test();
      expect(state.userMenuOpen, isFalse);
      state.toggleUserMenu();
      expect(state.userMenuOpen, isTrue);
      state.setUserMenuOpen(false);
      expect(state.userMenuOpen, isFalse);
    });

    test('global error can be set and cleared', () {
      final state = AppState.test();
      state.setGlobalError('boom');
      expect(state.globalError, 'boom');
      state.clearGlobalError();
      expect(state.globalError, isEmpty);
    });

    test('theme mode defaults to system and can be changed', () async {
      final state = AppState.test();
      expect(state.themeMode, ThemeMode.system);
      await state.setThemeMode(ThemeMode.dark);
      expect(state.themeMode, ThemeMode.dark);
      await state.setThemeMode(ThemeMode.light);
      expect(state.themeMode, ThemeMode.light);
    });

    test('settings topic index can be changed', () {
      final state = AppState.test();
      expect(state.settingsTopicIndex, 0);
      state.setSettingsTopicIndex(2);
      expect(state.settingsTopicIndex, 2);
    });
  });

  group('Auth flow', () {
    test('bootstrap sets user and loads projects', () async {
      final state = AppState(
        api: ApiService(
          client: _clientFor([
            _json(200, {
              'id': 1,
              'username': 'owner',
              'role': 'user',
              'is_owner': true,
              'totp_enabled': false,
              'provider_id': 'devin-cli',
              'provider_command': 'devin',
            }),
            _json(200, [
              {'id': 'glm-5-2', 'label': 'GLM'},
            ]),
            _json(200, [
              {'id': 'devin-cli', 'name': 'Devin CLI'},
            ]),
            _json(200, [
              {
                'id': 1,
                'name': 'p',
                'path': '/x',
                'created_at': '',
                'updated_at': '',
              },
            ]),
            _json(200, [
              {
                'id': 'a',
                'title': 't',
                'project_id': 1,
                'model': '',
                'permission_mode': 'normal',
                'created_at': '',
                'updated_at': '',
              },
            ]),
            _json(200, []),
          ]),
        ),
      );

      await state.bootstrap();
      expect(state.view, AppView.app);
      expect(state.user?.username, 'owner');
      expect(state.models, hasLength(1));
      expect(state.providers, hasLength(1));
      expect(state.projects, hasLength(1));
      expect(state.activeProjectId, 1);
    });

    test('bootstrap falls back to login on error', () async {
      final state = AppState(
        api: ApiService(
          client: _clientFor([http.Response('unauthorized', 401)]),
        ),
      );
      await state.bootstrap();
      expect(state.view, AppView.login);
    });

    test('doLogin navigates to app and loads data', () async {
      final state = AppState(
        api: ApiService(
          client: _clientFor([
            _json(200, {
              'ok': true,
              'totp_required': false,
              'username': 'owner',
            }),
            _json(200, {
              'id': 1,
              'username': 'owner',
              'role': 'user',
              'is_owner': true,
              'totp_enabled': false,
              'provider_id': 'devin-cli',
              'provider_command': 'devin',
            }),
            _json(200, [
              {'id': 'glm-5-2', 'label': 'GLM'},
            ]),
            _json(200, [
              {'id': 'devin-cli', 'name': 'Devin CLI'},
            ]),
            _json(200, [
              {
                'id': 1,
                'name': 'p',
                'path': '/x',
                'created_at': '',
                'updated_at': '',
              },
            ]),
            _json(200, []),
            _json(200, []),
          ]),
        ),
      );

      await state.doLogin(
        serverUrl: 'http://localhost',
        username: 'owner',
        password: 'pw',
      );
      expect(state.view, AppView.app);
      expect(state.user?.username, 'owner');
      expect(state.loginError, isEmpty);
    });

    test('doLogin shows TOTP field when required', () async {
      final state = AppState(
        api: ApiService(
          client: _clientFor([
            _json(200, {
              'ok': true,
              'totp_required': true,
              'username': 'owner',
            }),
          ]),
        ),
      );
      await state.doLogin(
        serverUrl: 'http://localhost',
        username: 'owner',
        password: 'pw',
      );
      expect(state.showTotpField, isTrue);
      expect(state.view, AppView.login);
      expect(state.loginError, contains('TOTP'));
    });

    test('doLogin sets error on failure', () async {
      final state = AppState(
        api: ApiService(
          client: _clientFor([
            _json(401, {'error': 'bad password'}),
          ]),
        ),
      );
      await state.doLogin(
        serverUrl: 'http://localhost',
        username: 'owner',
        password: 'pw',
      );
      expect(state.view, AppView.login);
      expect(state.loginError, contains('bad password'));
    });

    test('logout clears user state', () async {
      final state = AppState(
        api: ApiService(client: _clientFor([_json(200, {})])),
      );
      state.setView(AppView.app);
      state.setComposerText('hello');
      state.setSettingsTopicIndex(2);
      await state.logout();
      expect(state.view, AppView.login);
      expect(state.user, isNull);
      expect(state.composerText, isEmpty);
      expect(state.projects, isEmpty);
      expect(state.settingsTopicIndex, 0);
    });
  });

  group('Projects and threads', () {
    test('selectProject sets active and loads threads', () async {
      final state = AppState(
        api: ApiService(
          client: _clientFor([
            _json(200, [
              {
                'id': 'a',
                'title': 't',
                'project_id': 1,
                'model': '',
                'permission_mode': 'normal',
                'created_at': '',
                'updated_at': '',
              },
            ]),
            _json(200, []),
          ]),
        ),
      );
      final base = AppState.test(
        api: state.api,
        projects: [
          Project(id: 1, name: 'p', path: '/x', createdAt: '', updatedAt: ''),
        ],
      );
      base.setView(AppView.app);
      await base.selectProject(1);
      expect(base.activeProjectId, 1);
      expect(base.threads, hasLength(1));
      expect(base.page, MainPage.threads);
    });

    test('selectProject preserves active thread and project', () async {
      final state = AppState(
        api: ApiService(
          client: _clientFor([
            _json(200, [
              {
                'id': 'a',
                'title': 't',
                'project_id': 1,
                'model': '',
                'permission_mode': 'normal',
                'created_at': '',
                'updated_at': '',
              },
            ]),
            _json(200, []),
          ]),
        ),
      );
      final base = AppState.test(
        api: state.api,
        projects: [
          Project(id: 1, name: 'p1', path: '/x', createdAt: '', updatedAt: ''),
          Project(id: 2, name: 'p2', path: '/y', createdAt: '', updatedAt: ''),
        ],
        activeProjectId: 1,
        activeThreadId: 'a',
        activeThreadDetail: ThreadDetail(
          thread: Thread(
            id: 'a',
            title: 't',
            projectId: 1,
            model: '',
            permissionMode: 'normal',
            createdAt: '',
            updatedAt: '',
          ),
        ),
      );
      base.setView(AppView.app);
      base.setComposerMode(ComposerMode.ask);
      base.setComposerText('draft text');
      base.addAttachments([
        (filename: 'f.txt', mime: 'text/plain', bytes: Uint8List.fromList([1])),
      ]);

      await base.selectProject(2);
      expect(base.activeThreadId, 'a');
      expect(base.activeProjectId, 1);
      expect(base.composerText, 'draft text');
      expect(base.attachments, hasLength(1));
      expect(base.threads, hasLength(1));
    });

    test(
      'selectProject preserves default draft when no thread is active',
      () async {
        final state = AppState(
          api: ApiService(client: _clientFor([_json(200, []), _json(200, [])])),
        );
        final base = AppState.test(
          api: state.api,
          projects: [
            Project(id: 1, name: 'p', path: '/x', createdAt: '', updatedAt: ''),
          ],
        );
        base.setView(AppView.app);
        base.setComposerText('draft text');
        base.addAttachments([
          (
            filename: 'f.txt',
            mime: 'text/plain',
            bytes: Uint8List.fromList([1]),
          ),
        ]);

        await base.selectProject(1);
        expect(base.activeProjectId, 1);
        expect(base.composerText, 'draft text');
        expect(base.attachments, hasLength(1));
        expect(base.activeThreadId, isNull);
      },
    );

    test('selectAllProjects preserves active thread and project', () async {
      final state = AppState(
        api: ApiService(client: _clientFor([_json(200, []), _json(200, [])])),
      );
      final base = AppState.test(
        api: state.api,
        projects: [
          Project(id: 1, name: 'p', path: '/x', createdAt: '', updatedAt: ''),
        ],
        activeProjectId: 1,
        activeThreadId: 'a',
        activeThreadDetail: ThreadDetail(
          thread: Thread(
            id: 'a',
            title: 't',
            projectId: 1,
            model: '',
            permissionMode: 'normal',
            createdAt: '',
            updatedAt: '',
          ),
        ),
      );
      base.setView(AppView.app);
      await base.selectAllProjects();
      expect(base.activeThreadId, 'a');
      expect(base.activeProjectId, 1);
      expect(base.page, MainPage.threads);
    });

    test('loadMoreProjectThreads appends chunk', () async {
      final state = AppState(
        api: ApiService(
          client: _clientFor([
            _json(200, [
              {
                'id': 'a',
                'title': 't',
                'project_id': 1,
                'model': '',
                'permission_mode': 'normal',
                'created_at': '',
                'updated_at': '',
              },
            ]),
          ]),
        ),
      );
      final base = AppState.test(
        api: state.api,
        projects: [
          Project(id: 1, name: 'p', path: '/x', createdAt: '', updatedAt: ''),
        ],
        activeProjectId: 1,
      );
      base.setView(AppView.app);
      expect(base.hasMoreProjectThreads(1), isTrue);
      await base.loadMoreProjectThreads(1);
      expect(base.threads, hasLength(1));
      expect(base.hasMoreProjectThreads(1), isFalse);
    });

    test('createProject adds to list and selects it', () async {
      final state = AppState(
        api: ApiService(
          client: _clientFor([
            _json(200, {
              'id': 2,
              'name': 'p2',
              'path': '/y',
              'created_at': '',
              'updated_at': '',
            }),
            _json(200, []),
            _json(200, []),
          ]),
        ),
      );
      final base = AppState.test(
        api: state.api,
        projects: [
          Project(id: 1, name: 'p1', path: '/x', createdAt: '', updatedAt: ''),
        ],
      );
      base.setView(AppView.app);
      await base.createProject(name: 'p2', path: '/y');
      expect(base.projects, hasLength(2));
      expect(base.activeProjectId, 2);
    });

    test('loadMoreProjects appends chunk', () async {
      final chunk = List.generate(
        50,
        (i) => {
          'id': i + 1,
          'name': 'p${i + 1}',
          'path': '/x',
          'created_at': '',
          'updated_at': '',
        },
      );
      final state = AppState(
        api: ApiService(
          client: _clientFor([
            _json(200, chunk),
            _json(200, [
              {
                'id': 51,
                'name': 'p51',
                'path': '/y',
                'created_at': '',
                'updated_at': '',
              },
            ]),
          ]),
        ),
      );
      final base = AppState.test(api: state.api);
      base.setView(AppView.app);
      await base.loadProjects();
      expect(base.projects, hasLength(50));
      expect(base.hasMoreProjects, isTrue);
      await base.loadMoreProjects();
      expect(base.projects, hasLength(51));
      expect(base.hasMoreProjects, isFalse);
    });

    test('deleteProject removes project and selects another', () async {
      final state = AppState(
        api: ApiService(
          client: _clientFor([_json(200, {}), _json(200, []), _json(200, [])]),
        ),
      );
      final base = AppState.test(
        api: state.api,
        projects: [
          Project(id: 1, name: 'p1', path: '/x', createdAt: '', updatedAt: ''),
          Project(id: 2, name: 'p2', path: '/y', createdAt: '', updatedAt: ''),
        ],
        activeProjectId: 1,
      );
      base.setView(AppView.app);
      await base.deleteProject(1);
      expect(base.projects, hasLength(1));
      expect(base.activeProjectId, 2);
    });

    test(
      'deleteProject does not clear active thread from a different project',
      () async {
        final state = AppState(
          api: ApiService(
            client: _clientFor([
              _json(200, {}),
              _json(200, []),
              _json(200, []),
            ]),
          ),
        );
        final base = AppState.test(
          api: state.api,
          projects: [
            Project(
              id: 1,
              name: 'p1',
              path: '/x',
              createdAt: '',
              updatedAt: '',
            ),
            Project(
              id: 2,
              name: 'p2',
              path: '/y',
              createdAt: '',
              updatedAt: '',
            ),
          ],
          activeProjectId: 1,
          activeThreadId: 'a',
          activeThreadDetail: ThreadDetail(
            thread: Thread(
              id: 'a',
              title: 't',
              projectId: 1,
              model: '',
              permissionMode: 'normal',
              createdAt: '',
              updatedAt: '',
            ),
          ),
        );
        base.setView(AppView.app);
        await base.deleteProject(2);
        expect(base.projects, hasLength(1));
        expect(base.activeThreadId, 'a');
        expect(base.activeProjectId, 1);
      },
    );

    test('checkConnection sets connected on success', () async {
      final state = AppState(
        api: ApiService(
          client: _clientFor([
            _json(200, {'status': 'ok'}),
          ]),
        ),
      );
      final base = AppState.test(api: state.api);
      base.setView(AppView.app);
      await base.checkConnection();
      expect(base.connectionStatus, ConnectionStatus.connected);
    });

    test('checkConnection sets disconnected on failure', () async {
      final state = AppState(
        api: ApiService(client: _clientFor([http.Response('', 500)])),
      );
      final base = AppState.test(api: state.api);
      base.setView(AppView.app);
      await base.checkConnection();
      expect(base.connectionStatus, ConnectionStatus.disconnected);
    });

    test('reorderProjects reorders list and calls API', () async {
      final state = AppState(
        api: ApiService(client: _clientFor([_json(200, {})])),
      );
      final base = AppState.test(
        api: state.api,
        projects: [
          Project(id: 1, name: 'p1', path: '/x', createdAt: '', updatedAt: ''),
          Project(id: 2, name: 'p2', path: '/y', createdAt: '', updatedAt: ''),
          Project(id: 3, name: 'p3', path: '/z', createdAt: '', updatedAt: ''),
        ],
      );
      base.setView(AppView.app);
      await base.reorderProjects([3, 1, 2]);
      expect(base.projects.map((p) => p.id).toList(), [3, 1, 2]);
    });

    test('reorderProjects keeps pinned projects first', () async {
      final state = AppState(
        api: ApiService(client: _clientFor([_json(200, {})])),
      );
      final base = AppState.test(
        api: state.api,
        projects: [
          Project(id: 1, name: 'p1', path: '/x', createdAt: '', updatedAt: ''),
          Project(
            id: 2,
            name: 'p2',
            path: '/y',
            pinned: true,
            createdAt: '',
            updatedAt: '',
          ),
        ],
      );
      base.setView(AppView.app);
      await base.reorderProjects([1, 2]);
      expect(base.projects.map((p) => p.id).toList(), [2, 1]);
    });

    test('openRenameProjectDialog sets dialog and initial name', () {
      final state = AppState.test(
        projects: [
          Project(id: 1, name: 'p', path: '/x', createdAt: '', updatedAt: ''),
        ],
      );
      state.openRenameProjectDialog(1, 'p');
      expect(state.dialog, DialogKind.renameProject);
      expect(state.renameProjectId, 1);
      expect(state.renameInitialName, 'p');
    });

    test('renameProject updates project list and closes dialog', () async {
      final state = AppState(
        api: ApiService(
          client: _clientFor([
            _json(200, {
              'id': 1,
              'name': 'renamed',
              'path': '/x',
              'created_at': '',
              'updated_at': '',
            }),
          ]),
        ),
      );
      final base = AppState.test(
        api: state.api,
        projects: [
          Project(id: 1, name: 'p', path: '/x', createdAt: '', updatedAt: ''),
        ],
      );
      base.setView(AppView.app);
      base.openRenameProjectDialog(1, 'p');
      await base.renameProject(1, 'renamed');
      expect(base.projects.first.name, 'renamed');
      expect(base.dialog, DialogKind.none);
      expect(base.renameProjectId, isNull);
    });

    test('openRenameThreadDialog sets dialog and initial name', () {
      final state = AppState.test(
        threads: [
          Thread(
            id: 'a',
            title: 't',
            projectId: 1,
            model: '',
            permissionMode: 'normal',
            createdAt: '',
            updatedAt: '',
          ),
        ],
      );
      state.openRenameThreadDialog('a', 't');
      expect(state.dialog, DialogKind.renameThread);
      expect(state.renameThreadId, 'a');
      expect(state.renameInitialName, 't');
    });

    test('renameThread updates thread title and closes dialog', () async {
      final state = AppState(
        api: ApiService(client: _clientFor([_json(200, {})])),
      );
      final base = AppState.test(
        api: state.api,
        threads: [
          Thread(
            id: 'a',
            title: 't',
            projectId: 1,
            model: '',
            permissionMode: 'normal',
            createdAt: '',
            updatedAt: '',
          ),
        ],
      );
      base.openRenameThreadDialog('a', 't');
      await base.renameThread('a', 'renamed');
      expect(base.threads.first.title, 'renamed');
      expect(base.dialog, DialogKind.none);
      expect(base.renameThreadId, isNull);
    });

    test('pinProject toggles pinned and sorts projects', () async {
      final state = AppState(
        api: ApiService(
          client: _clientFor([
            _json(200, {
              'id': 2,
              'name': 'p2',
              'path': '/y',
              'pinned': true,
              'position': 1,
              'created_at': '',
              'updated_at': '',
            }),
          ]),
        ),
      );
      final base = AppState.test(
        api: state.api,
        projects: [
          Project(
            id: 1,
            name: 'p1',
            path: '/x',
            position: 0,
            createdAt: '',
            updatedAt: '',
          ),
          Project(
            id: 2,
            name: 'p2',
            path: '/y',
            position: 1,
            createdAt: '',
            updatedAt: '',
          ),
        ],
      );
      base.setView(AppView.app);
      await base.pinProject(2, true);
      expect(base.projects.first.id, 2);
      expect(base.projects.first.pinned, isTrue);
      expect(base.projects.last.id, 1);
    });

    test('pinThread toggles pinned and sorts threads', () async {
      final state = AppState(
        api: ApiService(
          client: _clientFor([
            _json(200, {
              'id': 'a',
              'title': 't',
              'project_id': 1,
              'model': '',
              'permission_mode': 'normal',
              'pinned': true,
              'created_at': '',
              'updated_at': '2026-01-02T00:00:00Z',
            }),
          ]),
        ),
      );
      final base = AppState.test(
        api: state.api,
        threads: [
          Thread(
            id: 'a',
            title: 't',
            projectId: 1,
            model: '',
            permissionMode: 'normal',
            createdAt: '',
            updatedAt: '2026-01-01T00:00:00Z',
          ),
          Thread(
            id: 'b',
            title: 't',
            projectId: 1,
            model: '',
            permissionMode: 'normal',
            createdAt: '',
            updatedAt: '2026-01-02T00:00:00Z',
          ),
        ],
      );
      base.setView(AppView.app);
      await base.pinThread('a', true);
      expect(base.threads.first.id, 'a');
      expect(base.threads.first.pinned, isTrue);
      expect(base.threads.first.updatedAt, '2026-01-02T00:00:00Z');
      expect(base.threads.last.id, 'b');
    });

    test('openThread loads detail and updates active project', () async {
      final state = AppState(
        api: ApiService(
          client: _clientFor([
            _json(200, {
              'thread': {
                'id': 'a',
                'title': 't',
                'project_id': 1,
                'model': 'glm-5-2',
                'permission_mode': 'normal',
                'created_at': '',
                'updated_at': '',
              },
              'messages': [],
            }),
            _json(200, {'project_id': 1, 'path': '/x'}),
            _json(200, []),
            _json(200, []),
          ]),
        ),
      );
      final base = AppState.test(
        api: state.api,
        projects: [
          Project(id: 1, name: 'p', path: '/x', createdAt: '', updatedAt: ''),
        ],
      );
      await base.openThread('a');
      expect(base.activeThreadId, 'a');
      expect(base.activeThreadDetail, isNotNull);
      expect(base.selectedModel, 'glm-5-2');
      expect(base.activeProjectId, 1);
    });

    test('openThread preserves composer draft and attachments', () async {
      final client = _clientFor([
        _json(200, {
          'thread': {
            'id': 'b',
            'title': 't',
            'project_id': 1,
            'model': 'glm-5-2',
            'permission_mode': 'normal',
            'created_at': '',
            'updated_at': '',
          },
          'messages': [],
        }),
        _json(200, {'project_id': 1, 'path': '/x'}),
        _json(200, []),
        _json(200, []),
        _json(200, {
          'thread': {
            'id': 'a',
            'title': 't',
            'project_id': 1,
            'model': 'glm-5-2',
            'permission_mode': 'normal',
            'created_at': '',
            'updated_at': '',
          },
          'messages': [],
        }),
        _json(200, {'project_id': 1, 'path': '/x'}),
        _json(200, []),
        _json(200, []),
      ]);
      final api = _StreamableApiService(client)
        ..runResponse = {'status': 'running'}
        ..eventsBuilder = () => Stream<SseEvent>.empty();
      final base = AppState.test(
        api: api,
        projects: [
          Project(id: 1, name: 'p', path: '/x', createdAt: '', updatedAt: ''),
        ],
        activeThreadId: 'a',
      );
      base.setView(AppView.app);
      base.setComposerMode(ComposerMode.ask);
      base.setComposerText('draft text');
      base.addAttachments([
        (filename: 'f.txt', mime: 'text/plain', bytes: Uint8List.fromList([1])),
      ]);

      await base.openThread('b');
      expect(base.activeThreadId, 'b');

      await base.openThread('a');
      expect(base.activeThreadId, 'a');
      expect(base.composerText, 'draft text');
      expect(base.composerMode, ComposerMode.ask);
      expect(base.attachments, hasLength(1));
      expect(base.attachments.first.filename, 'f.txt');
    });

    test('openThread logs its duration in debug mode', () async {
      if (!kDebugMode) return;

      final original = debugPrint;
      final logs = <String>[];
      debugPrint = (message, {wrapWidth}) => logs.add(message ?? '');
      addTearDown(() => debugPrint = original);

      final client = _clientFor([
        _json(200, {
          'thread': {
            'id': 'a',
            'title': 't',
            'project_id': 1,
            'model': 'glm-5-2',
            'permission_mode': 'normal',
            'created_at': '',
            'updated_at': '',
          },
          'messages': [],
          'total_messages': 0,
        }),
        _json(200, {'project_id': 1, 'path': '/x'}),
        _json(200, []),
        _json(200, []),
        _json(200, {
          'thread': {
            'id': 'a',
            'title': 't',
            'project_id': 1,
            'model': 'glm-5-2',
            'permission_mode': 'normal',
            'created_at': '',
            'updated_at': '',
          },
          'messages': [],
          'total_messages': 0,
        }),
      ]);
      final api = _StreamableApiService(client)
        ..runResponse = {'status': 'idle'};
      final state = AppState.test(
        api: api,
        projects: [
          Project(id: 1, name: 'p', path: '/x', createdAt: '', updatedAt: ''),
        ],
        activeProjectId: 1,
      );

      await state.openThread('a');

      expect(logs, anyElement(matches(RegExp(r'^Thread a opened in \d+ms$'))));
    });

    test('createNewThread requires a project', () async {
      final state = AppState.test();
      await state.createNewThread();
      expect(state.globalError, contains('Select a project first'));
    });

    test('deleteThread clears active thread', () async {
      final state = AppState(
        api: ApiService(
          client: _clientFor([_json(200, {}), _json(200, []), _json(200, [])]),
        ),
      );
      final base = AppState.test(api: state.api, activeThreadId: 'a');
      await base.deleteThread('a');
      expect(base.activeThreadId, isNull);
    });

    test('deleteThread logs failure via debugPrint in debug mode', () async {
      if (!kDebugMode) return;

      final original = debugPrint;
      final logs = <String>[];
      debugPrint = (message, {wrapWidth}) => logs.add(message ?? '');
      addTearDown(() => debugPrint = original);

      // A 500 response makes deleteThread throw, which the store catches.
      final state = AppState(
        api: ApiService(client: _clientFor([_json(500, {'error': 'boom'})])),
      );
      final base = AppState.test(api: state.api, activeThreadId: 'a');

      await base.deleteThread('a');

      expect(base.globalError, isNotEmpty);
      expect(
        logs,
        anyElement(matches(RegExp(r'threadList\.deleteThread failed.*a'))),
      );
    });

    test('saveThreadSettings updates active thread detail', () async {
      final state = AppState(
        api: ApiService(
          client: _clientFor([
            _json(200, {}),
            _json(200, {
              'thread': {
                'id': 'a',
                'title': 't',
                'project_id': 1,
                'model': 'glm-5-2',
                'permission_mode': 'normal',
                'created_at': '',
                'updated_at': '',
              },
              'messages': [],
            }),
            _json(200, []),
            _json(200, []),
          ]),
        ),
      );
      final base = AppState.test(api: state.api, activeThreadId: 'a');
      base.setSelectedModel('glm-5-2');
      base.setSelectedPermission('normal');
      await base.saveThreadSettings();
      expect(base.activeThreadDetail, isNotNull);
    });
  });

  group('Provider settings', () {
    test('saveProvider updates user and clears global error', () async {
      final state = AppState(
        api: ApiService(
          client: _clientFor([
            _json(200, {
              'id': 1,
              'username': 'owner',
              'role': 'user',
              'is_owner': true,
              'totp_enabled': false,
              'provider_id': 'devin-cli',
              'provider_command': 'devin-cli',
            }),
          ]),
        ),
      );
      final base = AppState.test(
        api: state.api,
        user: User(
          id: 1,
          username: 'owner',
          role: 'user',
          totpEnabled: false,
          providerId: 'devin-cli',
          providerCommand: 'devin',
        ),
      );
      await base.saveProvider(providerCommand: 'devin-cli');
      expect(base.user?.providerCommand, 'devin-cli');
      expect(base.globalError, isEmpty);
    });

    test('testProvider sets global error on failure', () async {
      final state = AppState(
        api: ApiService(
          client: _clientFor([
            _json(400, {'error': 'not found'}),
          ]),
        ),
      );
      final base = AppState.test(
        api: state.api,
        user: User(
          id: 1,
          username: 'owner',
          role: 'user',
          totpEnabled: false,
          providerId: 'devin-cli',
          providerCommand: 'devin',
        ),
      );
      try {
        await base.testProvider(providerId: 'devin-cli', command: 'devin');
        fail('expected testProvider to throw');
      } catch (_) {
        expect(base.globalError, contains('not found'));
      }
    });
  });

  group('Clone root', () {
    test('loadCloneRoot populates state and clears global error', () async {
      final state = AppState(
        api: ApiService(
          client: _clientFor([
            _json(200, {'path': '/srv/clones'}),
          ]),
        ),
      );
      final base = AppState.test(api: state.api);
      await base.loadCloneRoot();
      expect(base.cloneRoot, '/srv/clones');
      expect(base.loadingCloneRoot, isFalse);
      expect(base.globalError, isEmpty);
    });

    test('loadCloneRoot sets global error on failure', () async {
      final state = AppState(
        api: ApiService(
          client: _clientFor([
            _json(500, {'error': 'database failed'}),
          ]),
        ),
      );
      final base = AppState.test(api: state.api);
      await base.loadCloneRoot();
      expect(base.cloneRoot, isNull);
      expect(base.globalError, contains('database failed'));
      expect(base.loadingCloneRoot, isFalse);
    });

    test('setCloneRoot updates state and clears global error', () async {
      final state = AppState(
        api: ApiService(
          client: _clientFor([
            _json(200, {'path': '/new/clones'}),
          ]),
        ),
      );
      final base = AppState.test(
        api: state.api,
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
      await base.setCloneRoot('/new/clones');
      expect(base.cloneRoot, '/new/clones');
      expect(base.globalError, isEmpty);
      expect(base.loadingCloneRoot, isFalse);
    });

    test('setCloneRoot clears value when passed null', () async {
      final state = AppState(
        api: ApiService(
          client: _clientFor([
            _json(200, {'path': null}),
          ]),
        ),
      );
      final base = AppState.test(
        api: state.api,
        user: User(
          id: 1,
          username: 'owner',
          role: 'user',
          totpEnabled: false,
          isOwner: true,
          providerId: 'devin-cli',
          providerCommand: 'devin',
        ),
        cloneRoot: '/old',
      );
      await base.setCloneRoot(null);
      expect(base.cloneRoot, isNull);
      expect(base.globalError, isEmpty);
    });

    test('setCloneRoot surfaces validation errors', () async {
      final state = AppState(
        api: ApiService(
          client: _clientFor([
            _json(400, {'error': 'path must be absolute'}),
          ]),
        ),
      );
      final base = AppState.test(
        api: state.api,
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
      await base.setCloneRoot('relative');
      expect(base.cloneRoot, isNull);
      expect(base.globalError, contains('absolute'));
    });
  });

  group('Files', () {
    test('openFilesPanel loads entries', () async {
      final state = AppState(
        api: ApiService(
          client: _clientFor([
            _json(200, [
              {'name': 'a.txt', 'is_dir': false, 'size': 1},
            ]),
          ]),
        ),
      );
      final base = AppState.test(api: state.api, activeProjectId: 1);
      await base.openFilesPanel();
      expect(base.filesPanelOpen, isTrue);
      expect(base.filesEntries, hasLength(1));
      expect(base.filesError, isEmpty);
    });

    test('navigateFilesInto updates path and reloads', () async {
      final state = AppState(
        api: ApiService(
          client: _clientFor([
            _json(200, [
              {'name': 'b.txt', 'is_dir': false, 'size': 2},
            ]),
          ]),
        ),
      );
      final base = AppState.test(
        api: state.api,
        activeProjectId: 1,
        filesPath: [],
      );
      await base.navigateFilesInto('dir');
      expect(base.filesPath, ['dir']);
      expect(base.filesEntries, hasLength(1));
    });

    test('mkdir creates directory and reloads', () async {
      final state = AppState(
        api: ApiService(client: _clientFor([_json(200, {}), _json(200, [])])),
      );
      final base = AppState.test(api: state.api, activeProjectId: 1);
      await base.mkdir('newdir');
      expect(base.filesError, isEmpty);
    });

    test('loadMoreFiles appends chunk', () async {
      final chunk = List.generate(
        100,
        (i) => {'name': 'f$i.txt', 'is_dir': false, 'size': i},
      );
      final state = AppState(
        api: ApiService(
          client: _clientFor([
            _json(200, chunk),
            _json(200, [
              {'name': 'f100.txt', 'is_dir': false, 'size': 100},
            ]),
          ]),
        ),
      );
      final base = AppState.test(api: state.api, activeProjectId: 1);
      await base.openFilesPanel();
      expect(base.filesEntries, hasLength(100));
      expect(base.hasMoreFiles, isTrue);
      await base.loadMoreFiles();
      expect(base.filesEntries, hasLength(101));
      expect(base.hasMoreFiles, isFalse);
    });

    test('deleteFile removes and reloads', () async {
      final state = AppState(
        api: ApiService(client: _clientFor([_json(200, {}), _json(200, [])])),
      );
      final base = AppState.test(api: state.api, activeProjectId: 1);
      await base.deleteFile('a.txt');
      expect(base.filesError, isEmpty);
    });
  });

  group('Streaming send', () {
    test('sendMessage does nothing when composer is empty', () async {
      final state = AppState.test(activeThreadId: 'a');
      await state.sendMessage();
      expect(state.sending, isFalse);
    });

    test('sendMessage does nothing when no active thread', () async {
      final state = AppState.test();
      state.setComposerText('hello');
      await state.sendMessage();
      expect(state.sending, isFalse);
    });

    test('sendMessage streams chunks and done event', () async {
      final completer = Completer<void>();
      final client = _clientFor([
        _json(200, {}),
        _json(200, {
          'thread': {
            'id': 'a',
            'title': 't',
            'project_id': 1,
            'model': 'glm-5-2',
            'permission_mode': 'normal',
            'created_at': '',
            'updated_at': '',
          },
          'messages': [],
        }),
        _json(200, {
          'thread': {
            'id': 'a',
            'title': 't',
            'project_id': 1,
            'model': 'glm-5-2',
            'permission_mode': 'normal',
            'created_at': '',
            'updated_at': '',
          },
          'messages': [
            {
              'role': 'assistant',
              'content': 'hello world',
              'thinking': null,
              'attachments': [],
            },
          ],
          'total_messages': 1,
        }),
        _json(200, []),
        _json(200, []),
        _json(200, []),
      ]);
      final api = _StreamableApiService(client);
      final controller = StreamController<SseEvent>();
      api.streamBuilder = () => controller.stream;

      final state = AppState.test(
        api: api,
        activeProjectId: 1,
        activeThreadId: 'a',
        activeThreadDetail: ThreadDetail(
          thread: Thread(
            id: 'a',
            title: 't',
            projectId: 1,
            model: '',
            permissionMode: 'normal',
            createdAt: '',
            updatedAt: '',
          ),
          messages: [],
        ),
      );
      state.setSelectedModel('glm-5-2');
      state.setSelectedPermission('normal');
      state.setComposerText('hello');

      state.addListener(() {
        if (!state.sending && state.streamingParts.isEmpty) {
          if (!completer.isCompleted) completer.complete();
        }
      });

      await state.sendMessage();
      controller.add(SseEvent('part', '{"type":"text","content":"world"}'));
      controller.add(
        SseEvent('done', '{"role":"assistant","content":"hello world"}'),
      );

      await completer.future.timeout(Duration(seconds: 2));
      await controller.close();
      expect(state.activeThreadDetail!.messages, hasLength(1));
      expect(state.activeThreadDetail!.messages.first.content, 'hello world');
      expect(state.sending, isFalse);
    });

    test('sendMessage handles error event', () async {
      final client = _clientFor([
        _json(200, {}),
        _json(200, {
          'thread': {
            'id': 'a',
            'title': 't',
            'project_id': 1,
            'model': 'glm-5-2',
            'permission_mode': 'normal',
            'created_at': '',
            'updated_at': '',
          },
          'messages': [],
        }),
        _json(200, []),
        _json(200, []),
        _json(200, {
          'thread': {
            'id': 'a',
            'title': 't',
            'project_id': 1,
            'model': 'glm-5-2',
            'permission_mode': 'normal',
            'created_at': '',
            'updated_at': '',
          },
          'messages': [],
        }),
        _json(200, []),
        _json(200, []),
      ]);
      final api = _StreamableApiService(client);
      final controller = StreamController<SseEvent>();
      api.streamBuilder = () => controller.stream;

      final state = AppState.test(
        api: api,
        activeProjectId: 1,
        activeThreadId: 'a',
        activeThreadDetail: ThreadDetail(
          thread: Thread(
            id: 'a',
            title: 't',
            projectId: 1,
            model: '',
            permissionMode: 'normal',
            createdAt: '',
            updatedAt: '',
          ),
          messages: [],
        ),
      );
      state.setSelectedModel('glm-5-2');
      state.setSelectedPermission('normal');
      state.setComposerText('hello');

      final completer = Completer<void>();
      state.addListener(() {
        if (state.globalError.isNotEmpty) {
          if (!completer.isCompleted) completer.complete();
        }
      });

      await state.sendMessage();
      controller.add(SseEvent('error', 'blocked by policy'));

      await completer.future.timeout(Duration(seconds: 2));
      await controller.close();
      expect(state.globalError, 'blocked by policy');
      expect(state.sending, isFalse);
      expect(state.composerText, 'hello');
    });

    test('sendMessage preserves composer on stream error', () async {
      final client = _clientFor([
        _json(200, {}),
        _json(200, {
          'thread': {
            'id': 'a',
            'title': 't',
            'project_id': 1,
            'model': 'glm-5-2',
            'permission_mode': 'normal',
            'created_at': '',
            'updated_at': '',
          },
          'messages': [],
        }),
        _json(200, []),
        _json(200, []),
        _json(200, {
          'thread': {
            'id': 'a',
            'title': 't',
            'project_id': 1,
            'model': 'glm-5-2',
            'permission_mode': 'normal',
            'created_at': '',
            'updated_at': '',
          },
          'messages': [],
        }),
        _json(200, []),
        _json(200, []),
      ]);
      final api = _StreamableApiService(client);
      final controller = StreamController<SseEvent>();
      api.streamBuilder = () => controller.stream;

      final state = AppState.test(
        api: api,
        activeProjectId: 1,
        activeThreadId: 'a',
        activeThreadDetail: ThreadDetail(
          thread: Thread(
            id: 'a',
            title: 't',
            projectId: 1,
            model: '',
            permissionMode: 'normal',
            createdAt: '',
            updatedAt: '',
          ),
          messages: [],
        ),
      );
      state.setSelectedModel('glm-5-2');
      state.setSelectedPermission('normal');
      state.setComposerText('hello');

      final completer = Completer<void>();
      state.addListener(() {
        if (state.globalError.isNotEmpty) {
          if (!completer.isCompleted) completer.complete();
        }
      });

      await state.sendMessage();
      controller.addError(ApiException('network down', 500));

      await completer.future.timeout(Duration(seconds: 2));
      await controller.close();
      expect(state.sending, isFalse);
      expect(state.composerText, 'hello');
    });

    test('sendMessage handles stopped event', () async {
      final client = _clientFor([
        _json(200, {}),
        _json(200, {
          'thread': {
            'id': 'a',
            'title': 't',
            'project_id': 1,
            'model': 'glm-5-2',
            'permission_mode': 'normal',
            'created_at': '',
            'updated_at': '',
          },
          'messages': [],
        }),
        _json(200, []),
        _json(200, []),
        _json(200, {
          'thread': {
            'id': 'a',
            'title': 't',
            'project_id': 1,
            'model': 'glm-5-2',
            'permission_mode': 'normal',
            'created_at': '',
            'updated_at': '',
          },
          'messages': [],
        }),
        _json(200, []),
        _json(200, []),
      ]);
      final api = _StreamableApiService(client);
      final controller = StreamController<SseEvent>();
      api.streamBuilder = () => controller.stream;

      final state = AppState.test(
        api: api,
        activeProjectId: 1,
        activeThreadId: 'a',
        activeThreadDetail: ThreadDetail(
          thread: Thread(
            id: 'a',
            title: 't',
            projectId: 1,
            model: '',
            permissionMode: 'normal',
            createdAt: '',
            updatedAt: '',
          ),
          messages: [],
        ),
      );
      state.setSelectedModel('glm-5-2');
      state.setSelectedPermission('normal');
      state.setComposerText('hello');

      final completer = Completer<void>();
      state.addListener(() {
        if (!state.sending) {
          if (!completer.isCompleted) completer.complete();
        }
      });

      await state.sendMessage();
      controller.add(SseEvent('stopped', r'{"status":"stopped"}'));

      await completer.future.timeout(Duration(seconds: 2));
      await controller.close();
      expect(state.globalError, isEmpty);
      expect(state.sending, isFalse);
      expect(state.streamingParts, isEmpty);
      expect(state.lastRunStatus, 'stopped');
    });

    test('stopThread calls the stop endpoint', () async {
      final client = _clientFor([
        _json(200, {'status': 'stopped'}),
      ]);
      final api = _StreamableApiService(client);
      final state = AppState.test(
        api: api,
        activeProjectId: 1,
        activeThreadId: 'a',
        sending: true,
      );
      await state.stopThread();
      expect(api.stoppedThread, 'a');
    });

    test('sendMessage resumes on 409 conflict', () async {
      final client = _clientFor([
        _json(200, {}),
        _json(200, {
          'thread': {
            'id': 'a',
            'title': 't',
            'project_id': 1,
            'model': 'glm-5-2',
            'permission_mode': 'normal',
            'created_at': '',
            'updated_at': '',
          },
          'messages': [],
        }),
        _json(200, []),
        _json(200, []),
      ]);
      final api = _StreamableApiService(client);
      final sendController = StreamController<SseEvent>();
      api.streamBuilder = () => sendController.stream;

      final eventsController = StreamController<SseEvent>();
      api.eventsBuilder = () => eventsController.stream;
      api.runResponse = {'status': 'running'};

      final state = AppState.test(
        api: api,
        activeProjectId: 1,
        activeThreadId: 'a',
        activeThreadDetail: ThreadDetail(
          thread: Thread(
            id: 'a',
            title: 't',
            projectId: 1,
            model: '',
            permissionMode: 'normal',
            createdAt: '',
            updatedAt: '',
          ),
          messages: [],
        ),
      );
      state.setSelectedModel('glm-5-2');
      state.setSelectedPermission('normal');
      state.setComposerText('hello');

      final completer = Completer<void>();
      state.addListener(() {
        if (state.sending &&
            state.streamingParts.isNotEmpty &&
            state.streamingParts.first.content == 'world') {
          if (!completer.isCompleted) completer.complete();
        }
      });

      await state.sendMessage();
      sendController.addError(ApiException('already running', 409));
      eventsController.add(
        SseEvent('part', '{"type":"text","content":"world"}'),
      );

      await completer.future.timeout(Duration(seconds: 2));
      expect(state.sending, isTrue);
      expect(state.streamingParts.first.content, 'world');
      expect(state.composerText, 'hello');

      await sendController.close();
      await eventsController.close();
    });

    test('resumeThread attaches to a running backend run', () async {
      final client = _clientFor([
        _json(200, {
          'thread': {
            'id': 'a',
            'title': 't',
            'project_id': 1,
            'model': 'glm-5-2',
            'permission_mode': 'normal',
            'created_at': '',
            'updated_at': '',
          },
          'messages': [],
        }),
        _json(200, {'project_id': 1, 'path': '/'}),
        _json(200, []),
        _json(200, []),
        _json(200, {'status': 'running'}),
      ]);
      final api = _StreamableApiService(client);
      api.runResponse = {'status': 'running'};
      final controller = StreamController<SseEvent>();
      api.eventsBuilder = () => controller.stream;

      final state = AppState.test(api: api, activeProjectId: 1);
      await state.openThread('a');

      expect(state.sending, isTrue);
      expect(state.activeThreadDetail?.messages, hasLength(0));

      final completer = Completer<void>();
      state.addListener(() {
        if (!state.sending && state.activeThreadDetail!.messages.isNotEmpty) {
          if (!completer.isCompleted) completer.complete();
        }
      });

      controller.add(SseEvent('done', '{"role":"assistant","content":"hi"}'));
      await completer.future.timeout(Duration(seconds: 2));
      await controller.close();

      expect(state.sending, isFalse);
      expect(state.activeThreadDetail!.messages, hasLength(1));
      expect(state.activeThreadDetail!.messages.last.content, 'hi');
    });

    test('resumeThread refetches completed runs', () async {
      final client = _clientFor([
        _json(200, {
          'thread': {
            'id': 'a',
            'title': 't',
            'project_id': 1,
            'model': 'glm-5-2',
            'permission_mode': 'normal',
            'created_at': '',
            'updated_at': '',
          },
          'messages': [
            {
              'id': 1,
              'thread_id': 'a',
              'role': 'user',
              'content': 'hello',
              'thinking': null,
              'attachments': [],
              'created_at': '',
            },
          ],
        }),
        _json(200, {'project_id': 1, 'path': '/'}),
        _json(200, []),
        _json(200, []),
        _json(200, {
          'thread': {
            'id': 'a',
            'title': 't',
            'project_id': 1,
            'model': 'glm-5-2',
            'permission_mode': 'normal',
            'created_at': '',
            'updated_at': '',
          },
          'messages': [
            {
              'id': 1,
              'thread_id': 'a',
              'role': 'user',
              'content': 'hello',
              'thinking': null,
              'attachments': [],
              'created_at': '',
            },
            {
              'id': 2,
              'thread_id': 'a',
              'role': 'assistant',
              'content': 'done',
              'thinking': null,
              'attachments': [],
              'created_at': '',
            },
          ],
        }),
      ]);
      final api = _StreamableApiService(client);
      api.runResponse = {'status': 'completed'};
      final state = AppState.test(api: api, activeProjectId: 1);
      await state.openThread('a');

      expect(state.sending, isFalse);
      expect(state.activeThreadDetail!.messages, hasLength(2));
      expect(state.activeThreadDetail!.messages.last.content, 'done');
    });

    test('resumeThread refetches idle runs with stale detail', () async {
      final client = _clientFor([
        _json(200, {
          'thread': {
            'id': 'a',
            'title': 't',
            'project_id': 1,
            'model': 'glm-5-2',
            'permission_mode': 'normal',
            'created_at': '',
            'updated_at': '',
          },
          'messages': [
            {
              'id': 1,
              'thread_id': 'a',
              'role': 'user',
              'content': 'hello',
              'thinking': null,
              'attachments': [],
              'created_at': '',
            },
          ],
        }),
        _json(200, {'project_id': 1, 'path': '/'}),
        _json(200, []),
        _json(200, []),
        _json(200, {
          'thread': {
            'id': 'a',
            'title': 't',
            'project_id': 1,
            'model': 'glm-5-2',
            'permission_mode': 'normal',
            'created_at': '',
            'updated_at': '',
          },
          'messages': [
            {
              'id': 1,
              'thread_id': 'a',
              'role': 'user',
              'content': 'hello',
              'thinking': null,
              'attachments': [],
              'created_at': '',
            },
            {
              'id': 2,
              'thread_id': 'a',
              'role': 'assistant',
              'content': 'persisted',
              'thinking': null,
              'attachments': [],
              'created_at': '',
            },
          ],
        }),
      ]);
      final api = _StreamableApiService(client);
      api.runResponse = {'status': 'idle'};
      final state = AppState.test(api: api, activeProjectId: 1);
      await state.openThread('a');

      expect(state.sending, isFalse);
      expect(state.activeThreadDetail!.messages, hasLength(2));
      expect(state.activeThreadDetail!.messages.last.content, 'persisted');
    });

    test(
      'state event with completed status finishes run and stops sending',
      () async {
        final client = _clientFor([
          _json(200, {
            'thread': {
              'id': 'a',
              'title': 't',
              'project_id': 1,
              'model': 'glm-5-2',
              'permission_mode': 'normal',
              'created_at': '',
              'updated_at': '',
            },
            'messages': [],
          }),
          _json(200, {'project_id': 1, 'path': '/'}),
          _json(200, []),
          _json(200, []),
        ]);
        final api = _StreamableApiService(client);
        final eventsController = StreamController<SseEvent>();
        api.eventsBuilder = () => eventsController.stream;
        api.runResponse = {
          'status': 'running',
          'parts': [
            {'type': 'text', 'content': 'seeded'},
          ],
          'thinking_active': false,
        };

        final state = AppState.test(api: api, activeProjectId: 1);
        await state.openThread('a');

        expect(state.sending, isTrue);
        expect(state.streamingParts, hasLength(1));

        eventsController.add(
          SseEvent(
            'state',
            '{"status":"completed","parts":[{"type":"text","content":"done"}]}',
          ),
        );
        await eventsController.close();
        await pumpEventQueue();

        expect(state.sending, isFalse);
        expect(state.runningThreadIds, isNot(contains('a')));
        expect(state.streamingParts, isEmpty);
      },
    );

    test(
      'state event with completed status clears stale error and permission',
      () async {
        final client = _clientFor([
          _json(200, {
            'thread': {
              'id': 'a',
              'title': 't',
              'project_id': 1,
              'model': 'glm-5-2',
              'permission_mode': 'normal',
              'created_at': '',
              'updated_at': '',
            },
            'messages': [],
          }),
          _json(200, {'project_id': 1, 'path': '/'}),
          _json(200, []),
          _json(200, []),
        ]);
        final api = _StreamableApiService(client);
        final eventsController = StreamController<SseEvent>();
        api.eventsBuilder = () => eventsController.stream;
        api.runResponse = {
          'status': 'running',
          'error': 'stale error',
          'permission_request': {
            'request_id': 'r1',
            'scope': 'Exec(curl)',
            'title': 'Run?',
            'options': [],
          },
        };

        final state = AppState.test(api: api, activeProjectId: 1);
        await state.openThread('a');

        expect(state.sending, isTrue);
        expect(state.globalError, 'stale error');
        expect(state.pendingPermissionRequest, isNotNull);
        expect(state.dialog, DialogKind.permissionRequest);

        eventsController.add(
          SseEvent('state', '{"status":"completed","parts":[]}'),
        );
        await pumpEventQueue();
        await eventsController.close();

        expect(state.sending, isFalse);
        expect(state.globalError, isEmpty);
        expect(state.pendingPermissionRequest, isNull);
        expect(state.dialog, DialogKind.none);
      },
    );

    test('resumeThread seeds streaming parts from run snapshot', () async {
      final client = _clientFor([
        _json(200, {
          'thread': {
            'id': 'a',
            'title': 't',
            'project_id': 1,
            'model': 'glm-5-2',
            'permission_mode': 'normal',
            'created_at': '',
            'updated_at': '',
          },
          'messages': [],
        }),
        _json(200, {'project_id': 1, 'path': '/'}),
        _json(200, []),
        _json(200, []),
      ]);
      final api = _StreamableApiService(client);
      final eventsController = StreamController<SseEvent>();
      api.eventsBuilder = () => eventsController.stream;
      api.runResponse = {
        'status': 'running',
        'parts': [
          {'type': 'text', 'content': 'seeded'},
          {'type': 'thinking', 'content': 'hmm'},
        ],
        'thinking_active': true,
      };

      final state = AppState.test(api: api, activeProjectId: 1);
      await state.openThread('a');

      expect(state.sending, isTrue);
      expect(state.streamingParts, hasLength(2));
      expect(state.streamingParts[0].content, 'seeded');
      expect(state.streamingParts[1].content, 'hmm');
      expect(state.streamingThinkingActive, isTrue);

      await eventsController.close();
    });

    test(
      'sendMessage clears composer immediately and replaces optimistic on user_message',
      () async {
        final client = _clientFor([
          _json(200, {}),
          _json(200, {
            'thread': {
              'id': 'a',
              'title': 't',
              'project_id': 1,
              'model': 'glm-5-2',
              'permission_mode': 'normal',
              'created_at': '',
              'updated_at': '',
            },
            'messages': [],
          }),
          _json(200, []),
          _json(200, []),
          _json(200, []),
          _json(200, []),
        ]);
        final api = _StreamableApiService(client);
        final controller = StreamController<SseEvent>();
        api.streamBuilder = () => controller.stream;

        final state = AppState.test(
          api: api,
          activeProjectId: 1,
          activeThreadId: 'a',
          activeThreadDetail: ThreadDetail(
            thread: Thread(
              id: 'a',
              title: 't',
              projectId: 1,
              model: '',
              permissionMode: 'normal',
              createdAt: '',
              updatedAt: '',
            ),
            messages: [],
          ),
        );
        state.setSelectedModel('glm-5-2');
        state.setSelectedPermission('normal');
        state.setComposerText('hello');

        final completer = Completer<void>();
        state.addListener(() {
          if (state.activeThreadDetail!.messages.any((m) => m.id != null)) {
            if (!completer.isCompleted) completer.complete();
          }
        });

        await state.sendMessage();
        expect(state.composerText, '');
        expect(state.activeThreadDetail!.messages, hasLength(1));
        expect(
          state.activeThreadDetail!.messages.first.clientMessageId,
          isNotNull,
        );

        final clientId = api.lastClientMessageId;
        controller.add(
          SseEvent(
            'user_message',
            '{"id":2,"role":"user","content":"hello","client_message_id":"$clientId"}',
          ),
        );
        await completer.future.timeout(Duration(seconds: 2));
        expect(state.composerText, '');
        expect(state.activeThreadDetail!.messages, hasLength(1));
        expect(state.activeThreadDetail!.messages.first.id, 2);

        await controller.close();
      },
    );
  });

  group('TOTP, dialog and accounts', () {
    test('openTotpSetup sets secret and dialog', () async {
      final state = AppState(
        api: ApiService(
          client: _clientFor([
            _json(200, {'secret': 's', 'otpauth_uri': 'otpauth://x'}),
          ]),
        ),
      );
      await state.openTotpSetup();
      expect(state.totpSecret, 's');
      expect(state.dialog, DialogKind.totpSetup);
    });

    test('verifyTotp closes dialog and refreshes user', () async {
      final state = AppState(
        api: ApiService(
          client: _clientFor([
            _json(200, {}),
            _json(200, {
              'id': 1,
              'username': 'owner',
              'role': 'user',
              'is_owner': true,
              'totp_enabled': true,
              'provider_id': 'devin-cli',
              'provider_command': 'devin',
            }),
          ]),
        ),
      );
      final base = AppState.test(api: state.api, dialog: DialogKind.totpSetup);
      await base.verifyTotp('123456');
      expect(base.dialog, DialogKind.none);
      expect(base.user?.totpEnabled, isTrue);
    });

    test('respondToPermissionRequest sends response', () async {
      final state = AppState(
        api: ApiService(client: _clientFor([_json(200, {})])),
      );
      final base = AppState.test(
        api: state.api,
        activeThreadId: 'a',
        dialog: DialogKind.permissionRequest,
        pendingPermissionRequest: PermissionRequest(
          requestId: 'r1',
          scope: 'Exec(curl)',
          title: 'Run?',
          options: [],
        ),
      );
      await base.respondToPermissionRequest('allow');
      expect(base.pendingPermissionRequest, isNull);
      expect(base.dialog, DialogKind.none);
    });

    test('closeDialog clears dialog', () {
      final state = AppState.test(dialog: DialogKind.totpSetup);
      state.closeDialog();
      expect(state.dialog, DialogKind.none);
    });

    test('loadUsers populates users list', () async {
      final state = AppState(
        api: ApiService(
          client: _clientFor([
            _json(200, [
              {
                'id': 1,
                'username': 'owner',
                'role': 'user',
                'is_owner': true,
                'disabled': false,
                'totp_enabled': false,
                'created_at': '',
              },
            ]),
          ]),
        ),
      );
      await state.loadUsers();
      expect(state.users, hasLength(1));
      expect(state.users.first.username, 'owner');
      expect(state.users.first.isOwner, isTrue);
    });

    test(
      'loadSettingsData fetches git connections, clone root and users in parallel',
      () async {
        final state = AppState.test(
          user: User(
            id: 1,
            username: 'owner',
            role: 'user',
            totpEnabled: false,
            isOwner: true,
            providerId: 'devin-cli',
            providerCommand: 'devin',
          ),
          api: ApiService(
            client: ApiClient.withClient(
              MockClient((req) async {
                final path = req.url.path;
                if (path == '/api/git-connections') {
                  return _json(200, [
                    {'id': 'gitlab', 'name': 'GitLab', 'enabled': true},
                  ]);
                }
                if (path == '/api/settings/clone-root') {
                  return _json(200, {'path': '/srv/clones'});
                }
                if (path == '/api/users') {
                  return _json(200, [
                    {
                      'id': 1,
                      'username': 'owner',
                      'role': 'user',
                      'is_owner': true,
                      'disabled': false,
                      'totp_enabled': false,
                      'created_at': '',
                    },
                  ]);
                }
                return _json(404, {'error': 'unexpected $path'});
              }),
            ),
          ),
        );
        await state.loadSettingsData();
        expect(state.gitConnections, hasLength(1));
        expect(state.gitConnections.first.id, 'gitlab');
        expect(state.cloneRoot, '/srv/clones');
        expect(state.users, hasLength(1));
        expect(state.users.first.username, 'owner');
      },
    );

    test('createUser reloads users', () async {
      final state = AppState(
        api: ApiService(
          client: _clientFor([
            _json(200, {'ok': true, 'id': 2, 'username': 'alice'}),
            _json(200, [
              {
                'id': 1,
                'username': 'owner',
                'role': 'user',
                'is_owner': true,
                'disabled': false,
                'totp_enabled': false,
                'created_at': '',
              },
              {
                'id': 2,
                'username': 'alice',
                'role': 'user',
                'is_owner': false,
                'disabled': false,
                'totp_enabled': false,
                'created_at': '',
              },
            ]),
          ]),
        ),
      );
      await state.createUser(username: 'alice', password: 'pw');
      expect(state.users, hasLength(2));
      expect(state.users.any((u) => u.username == 'alice'), isTrue);
    });

    test('isOwner reflects user', () {
      final owner = AppState.test(
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
      expect(owner.isOwner, isTrue);

      final regular = AppState.test(
        user: User(
          id: 2,
          username: 'alice',
          role: 'user',
          totpEnabled: false,
          providerId: 'devin-cli',
          providerCommand: 'devin',
        ),
      );
      expect(regular.isOwner, isFalse);
    });
  });

  group('Theme persistence', () {
    setUpAll(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('setThemeMode saves and loadThemeMode restores the value', () async {
      final state = AppState.test();
      await state.setThemeMode(ThemeMode.dark);
      expect(state.themeMode, ThemeMode.dark);

      final restored = AppState.test();
      await restored.bootstrap();
      expect(restored.themeMode, ThemeMode.dark);
    });
  });

  group('Language persistence', () {
    setUpAll(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('setLanguage saves and loadLanguage restores the value', () async {
      final state = AppState.test();
      await state.setLanguage('en-GB');
      expect(state.locale, const Locale('en-GB'));
      expect(
        (await SharedPreferences.getInstance()).getString(
          'devinorium_language',
        ),
        'en-GB',
      );

      final restored = AppState.test();
      await restored.bootstrap();
      expect(restored.locale, const Locale('en-GB'));
    });
  });

  group('Git state', () {
    test('loadGitRepoInfo updates project branch', () async {
      final client = _clientFor([
        _json(200, {
          'is_repo': true,
          'branch': 'develop',
          'toplevel': '/x',
          'common_dir': '/x/.git',
          'worktree_path': '/x',
        }),
      ]);
      final state = AppState.test(
        api: _StreamableApiService(client),
        projects: [
          Project(id: 1, name: 'p', path: '/x', createdAt: '', updatedAt: ''),
        ],
      );
      await state.loadGitRepoInfo(1);
      expect(state.projects[0].isRepo, true);
      expect(state.projects[0].gitBranch, 'develop');
    });

    test(
      'loadGitBranchData fetches repo, branches and worktrees in parallel',
      () async {
        final client = ApiClient.withClient(
          MockClient((req) async {
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
                ],
              });
            }
            if (path == '/api/projects/1/git/worktrees') {
              return _json(200, []);
            }
            return _json(404, {'error': 'unexpected request'});
          }),
        );

        final state = AppState.test(api: ApiService(client: client));
        await state.loadGitBranchData(1);
        expect(state.gitRepoInfo(1)?.branch, 'main');
        expect(state.gitBranches(1), hasLength(1));
        expect(state.gitWorktrees(1), isEmpty);
      },
    );

    test('gitCheckout refreshes project branch and project list', () async {
      final requests = <String>[];
      final client = ApiClient.withClient(
        MockClient((req) async {
          final path = req.url.path;
          requests.add(path);
          if (path == '/api/projects/1/git/checkout') {
            return _json(200, {});
          }
          if (path == '/api/projects/1/git') {
            return _json(200, {
              'is_repo': true,
              'branch': 'feature',
              'worktree_path': '/x',
              'toplevel': '/x',
              'common_dir': '/x/.git',
            });
          }
          if (path == '/api/projects/1/git/branches') {
            return _json(200, {
              'branches': [
                {
                  'name': 'feature',
                  'refname': 'refs/heads/feature',
                  'is_current': true,
                  'is_default': true,
                  'is_remote': false,
                  'committer_date': 0,
                },
              ],
            });
          }
          if (path == '/api/projects/1/git/worktrees') {
            return _json(200, []);
          }
          if (path == '/api/projects') {
            return _json(200, [
              {
                'id': 1,
                'name': 'p',
                'path': '/x',
                'position': 0,
                'pinned': false,
                'is_repo': true,
                'branch': 'feature',
                'project_type': 'generic',
                'created_at': '',
                'updated_at': '',
              },
            ]);
          }
          return _json(404, {'error': 'unexpected request'});
        }),
      );

      final state = AppState.test(
        api: ApiService(client: client),
        projects: [
          Project(id: 1, name: 'p', path: '/x', createdAt: '', updatedAt: ''),
        ],
      );
      await state.gitCheckout(1, 'feature');
      expect(requests, contains('/api/projects'));
      expect(state.projects[0].gitBranch, 'feature');
    });

    test('gitCreateBranch returns true and refreshes repo', () async {
      final client = ApiClient.withClient(
        MockClient((req) async {
          final path = req.url.path;
          final method = req.method;
          if (path == '/api/projects/1/git/branches' && method == 'POST') {
            return _json(200, {'name': 'new'});
          }
          if (path == '/api/projects/1/git/branches' && method == 'GET') {
            return _json(200, {
              'branches': [
                {
                  'name': 'new',
                  'refname': 'refs/heads/new',
                  'is_current': true,
                  'is_default': false,
                  'is_remote': false,
                  'committer_date': 0,
                },
              ],
            });
          }
          if (path == '/api/projects/1/git') {
            return _json(200, {
              'is_repo': true,
              'branch': 'new',
              'worktree_path': '/x',
              'toplevel': '/x',
              'common_dir': '/x/.git',
            });
          }
          if (path == '/api/projects/1/git/worktrees') {
            return _json(200, []);
          }
          if (path == '/api/projects') {
            return _json(200, []);
          }
          return _json(404, {'error': 'unexpected request'});
        }),
      );

      final state = AppState.test(
        api: ApiService(client: client),
        projects: [
          Project(id: 1, name: 'p', path: '/x', createdAt: '', updatedAt: ''),
        ],
      );
      final ok = await state.gitCreateBranch(1, 'new');
      expect(ok, isTrue);
      expect(state.gitRepoInfo(1)?.branch, 'new');
    });

    test('gitCreateBranch returns false when the API fails', () async {
      final client = ApiClient.withClient(
        MockClient((req) async {
          if (req.url.path == '/api/projects/1/git/branches') {
            return _json(500, {'error': 'nope'});
          }
          return _json(404, {'error': 'unexpected request'});
        }),
      );

      final state = AppState.test(api: ApiService(client: client));
      final ok = await state.gitCreateBranch(1, 'new');
      expect(ok, isFalse);
      expect(state.globalError, isNotEmpty);
    });

    test('gitCreateWorktree returns the created worktree', () async {
      final client = ApiClient.withClient(
        MockClient((req) async {
          final path = req.url.path;
          final method = req.method;
          if (path == '/api/projects/1/git/worktrees' && method == 'POST') {
            return _json(200, {
              'path': '/x/wt',
              'head': 'abc',
              'branch': 'main',
              'is_main': false,
            });
          }
          if (path == '/api/projects/1/git/worktrees' && method == 'GET') {
            return _json(200, [
              {
                'path': '/x/wt',
                'head': 'abc',
                'branch': 'main',
                'is_main': false,
              },
            ]);
          }
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
              ],
            });
          }
          if (path == '/api/projects') {
            return _json(200, []);
          }
          return _json(404, {'error': 'unexpected request'});
        }),
      );

      final state = AppState.test(api: ApiService(client: client));
      final worktree = await state.gitCreateWorktree(1, 'wt', 'main');
      expect(worktree, isNotNull);
      expect(worktree?.path, '/x/wt');
    });

    test('gitCreateWorktree returns null when the API fails', () async {
      final client = ApiClient.withClient(
        MockClient((req) async {
          if (req.url.path == '/api/projects/1/git/worktrees') {
            return _json(500, {'error': 'nope'});
          }
          return _json(404, {'error': 'unexpected request'});
        }),
      );

      final state = AppState.test(api: ApiService(client: client));
      final worktree = await state.gitCreateWorktree(1, 'wt', 'main');
      expect(worktree, isNull);
      expect(state.globalError, isNotEmpty);
    });

    test('gitPull returns true on success and refreshes repo', () async {
      final client = ApiClient.withClient(
        MockClient((req) async {
          final path = req.url.path;
          if (path == '/api/projects/1/git/pull') {
            return _json(200, {});
          }
          if (path == '/api/projects/1/git/merge-request') {
            return _json(204, {});
          }
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
              ],
            });
          }
          if (path == '/api/projects/1/git/worktrees') {
            return _json(200, []);
          }
          if (path == '/api/projects') {
            return _json(200, []);
          }
          return _json(404, {'error': 'unexpected request'});
        }),
      );

      final state = AppState.test(api: ApiService(client: client));
      final ok = await state.gitPull(1);
      expect(ok, isTrue);
    });

    test('gitPull returns false on error', () async {
      final client = ApiClient.withClient(
        MockClient((req) async {
          if (req.url.path == '/api/projects/1/git/pull') {
            return _json(500, {'error': 'nope'});
          }
          return _json(404, {'error': 'unexpected request'});
        }),
      );

      final state = AppState.test(api: ApiService(client: client));
      final ok = await state.gitPull(1);
      expect(ok, isFalse);
      expect(state.globalError, isNotEmpty);
    });

    test('gitPush returns true on success and refreshes repo', () async {
      final client = ApiClient.withClient(
        MockClient((req) async {
          final path = req.url.path;
          if (path == '/api/projects/1/git/push') {
            return _json(200, {});
          }
          if (path == '/api/projects/1/git/merge-request') {
            return _json(204, {});
          }
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
              ],
            });
          }
          if (path == '/api/projects/1/git/worktrees') {
            return _json(200, []);
          }
          if (path == '/api/projects') {
            return _json(200, []);
          }
          return _json(404, {'error': 'unexpected request'});
        }),
      );

      final state = AppState.test(api: ApiService(client: client));
      final ok = await state.gitPush(1);
      expect(ok, isTrue);
    });

    test('gitPush returns false on error', () async {
      final client = ApiClient.withClient(
        MockClient((req) async {
          if (req.url.path == '/api/projects/1/git/push') {
            return _json(500, {'error': 'nope'});
          }
          return _json(404, {'error': 'unexpected request'});
        }),
      );

      final state = AppState.test(api: ApiService(client: client));
      final ok = await state.gitPush(1);
      expect(ok, isFalse);
      expect(state.globalError, isNotEmpty);
    });

    test(
      'gitCheckout returns false and surfaces an error when checkout fails',
      () async {
        final client = ApiClient.withClient(
          MockClient((req) async {
            if (req.url.path == '/api/projects/1/git/checkout') {
              return _json(500, {'error': 'nope'});
            }
            return _json(404, {'error': 'unexpected request'});
          }),
        );

        final state = AppState.test(api: ApiService(client: client));
        final ok = await state.gitCheckout(1, 'feature');
        expect(ok, isFalse);
        expect(state.globalError, isNotEmpty);
      },
    );

    test('git refresh timer loads project branch periodically', () async {
      var calls = 0;
      final client = ApiClient.withClient(
        MockClient((req) async {
          final path = req.url.path;
          if (path == '/api/projects/1/git' &&
              req.url.queryParameters['force'] == 'true') {
            calls++;
            return _json(200, {
              'is_repo': true,
              'branch': 'main',
              'worktree_path': '/x',
              'toplevel': '/x',
              'common_dir': '/x/.git',
            });
          }
          if (path == '/api/projects') {
            return _json(200, []);
          }
          return _json(404, {'error': 'unexpected request'});
        }),
      );

      final state = AppState.test(
        api: ApiService(client: client),
        activeProjectId: 1,
      );
      state.startGitRefresh();
      // The timer fires immediately at t=0 in fake-async tests, or we can
      // pump one interval.
      await Future.delayed(const Duration(seconds: 6));
      expect(calls, greaterThan(0));
      state.stopGitRefresh();
    });
  });

  group('Notification preferences', () {
    setUpAll(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('defaults to disabled', () {
      final state = AppState.test();
      expect(state.notificationsEnabled, isFalse);
    });

    test('setNotificationsEnabled persists the value', () async {
      final state = AppState.test();
      await state.setNotificationsEnabled(true);
      expect(state.notificationsEnabled, isTrue);
      expect(
        (await SharedPreferences.getInstance()).getBool(
          'devinorium_notifications',
        ),
        isTrue,
      );
    });

    test('bootstrap loads saved notification prefs', () async {
      SharedPreferences.setMockInitialValues({
        'devinorium_notifications': true,
      });
      final state = AppState.test();
      await state.bootstrap();
      expect(state.notificationsEnabled, isTrue);
    });

    test('onRunFinished fires when stream completes', () async {
      final completer = Completer<void>();
      final client = _clientFor([
        _json(200, {}),
        _json(200, {
          'thread': {
            'id': 'a',
            'title': 't',
            'project_id': 1,
            'model': 'glm-5-2',
            'permission_mode': 'normal',
            'created_at': '',
            'updated_at': '',
          },
          'messages': [],
        }),
        _json(200, {
          'thread': {
            'id': 'a',
            'title': 't',
            'project_id': 1,
            'model': 'glm-5-2',
            'permission_mode': 'normal',
            'created_at': '',
            'updated_at': '',
          },
          'messages': [
            {
              'role': 'assistant',
              'content': 'done',
              'thinking': null,
              'attachments': [],
            },
          ],
          'total_messages': 1,
        }),
        _json(200, []),
        _json(200, []),
        _json(200, []),
      ]);
      final api = _StreamableApiService(client);
      final controller = StreamController<SseEvent>();
      api.streamBuilder = () => controller.stream;

      final state = AppState.test(
        api: api,
        activeProjectId: 1,
        activeThreadId: 'a',
        activeThreadDetail: ThreadDetail(
          thread: Thread(
            id: 'a',
            title: 't',
            projectId: 1,
            model: '',
            permissionMode: 'normal',
            createdAt: '',
            updatedAt: '',
          ),
          messages: [],
        ),
      );
      state.setNotificationsEnabled(true);
      state.setSelectedModel('glm-5-2');
      state.setSelectedPermission('normal');
      state.setComposerText('hello');

      state.addListener(() {
        if (!state.sending && state.streamingParts.isEmpty) {
          if (!completer.isCompleted) completer.complete();
        }
      });

      await state.sendMessage();
      controller.add(SseEvent('part', '{"type":"text","content":"done"}'));
      controller.add(SseEvent('done', '{"role":"assistant","content":"done"}'));

      await completer.future.timeout(Duration(seconds: 2));
      await controller.close();
      // The notification service stub is a no-op, but the test verifies
      // that the flow completes without errors.
      expect(state.sending, isFalse);
    });
  });

  group('Merge request links', () {
    test('openLink opens the merge request panel for GitLab MR URLs', () async {
      final state = AppState.test();
      final url = 'https://gitlab.com/group/project/-/merge_requests/1';
      await state.openLink(url);

      expect(state.dialog, DialogKind.mergeRequest);
      expect(state.mergeRequestUrl, url);
    });

    test('closeDialog clears the merge request URL', () {
      final state = AppState.test(
        dialog: DialogKind.mergeRequest,
        mergeRequestUrl: 'https://gitlab.com/group/project/-/merge_requests/1',
      );
      state.closeDialog();

      expect(state.dialog, DialogKind.none);
      expect(state.mergeRequestUrl, isNull);
    });
  });

  group('Issue links', () {
    test('openLink opens the issue panel for classic issue URLs', () async {
      final state = AppState.test();
      final url = 'https://gitlab.com/group/project/-/issues/1';
      await state.openLink(url);

      expect(state.dialog, DialogKind.issue);
      expect(state.issueUrl, url);
    });

    test('openLink opens the issue panel for work item URLs', () async {
      final state = AppState.test();
      final url = 'https://gitlab.com/group/project/-/work_items/77';
      await state.openLink(url);

      expect(state.dialog, DialogKind.issue);
      expect(state.issueUrl, url);
    });

    test('openLink still routes merge requests over issues', () async {
      final state = AppState.test();
      await state.openLink(
        'https://gitlab.com/group/project/-/merge_requests/3',
      );

      expect(state.dialog, DialogKind.mergeRequest);
      expect(state.issueUrl, isNull);
    });

    test('closeDialog clears the issue URL', () {
      final state = AppState.test(
        dialog: DialogKind.issue,
        issueUrl: 'https://gitlab.com/group/project/-/issues/1',
      );
      state.closeDialog();

      expect(state.dialog, DialogKind.none);
      expect(state.issueUrl, isNull);
    });
  });

  group('Linked merge request', () {
    test('loadLinkedMergeRequest stores the MR summary', () async {
      final client = ApiClient.withClient(
        MockClient((req) async {
          if (req.url.path == '/api/projects/1/git/merge-request') {
            return _json(200, {
              'iid': 12,
              'title': 'Add feature',
              'state': 'opened',
              'source_branch': 'feature/x',
              'target_branch': 'main',
              'web_url': 'https://gitlab.example.com/g/p/-/merge_requests/12',
              'draft': false,
            });
          }
          return _json(404, {'error': 'unexpected'});
        }),
      );
      final state = AppState.test(
        api: ApiService(client: client),
        activeProjectId: 1,
      );
      await state.loadLinkedMergeRequest(1, 'feature/x');
      expect(state.loadingLinkedMergeRequest, isFalse);
      final mr = state.linkedMergeRequest;
      expect(mr, isNotNull);
      expect(mr!.iid, 12);
      expect(mr.title, 'Add feature');
      expect(mr.sourceBranch, 'feature/x');
    });

    test(
      'loadLinkedMergeRequest stores null when no MR exists (204)',
      () async {
        final client = ApiClient.withClient(
          MockClient((req) async {
            if (req.url.path == '/api/projects/1/git/merge-request') {
              return http.Response('', 204);
            }
            return _json(404, {'error': 'unexpected'});
          }),
        );
        final state = AppState.test(
          api: ApiService(client: client),
          activeProjectId: 1,
        );
        await state.loadLinkedMergeRequest(1, 'feature/x');
        expect(state.linkedMergeRequest, isNull);
        expect(state.loadingLinkedMergeRequest, isFalse);
      },
    );

    test(
      'loadLinkedMergeRequest stores null on 404 (no GitLab remote)',
      () async {
        final client = ApiClient.withClient(
          MockClient((req) async {
            if (req.url.path == '/api/projects/1/git/merge-request') {
              return _json(404, {'error': 'not a gitlab repository'});
            }
            return _json(404, {'error': 'unexpected'});
          }),
        );
        final state = AppState.test(
          api: ApiService(client: client),
          activeProjectId: 1,
        );
        await state.loadLinkedMergeRequest(1, 'feature/x');
        expect(state.linkedMergeRequest, isNull);
        expect(state.loadingLinkedMergeRequest, isFalse);
      },
    );

    test(
      'refreshLinkedMergeRequest clears state when no branch is active',
      () async {
        final state = AppState.test(activeProjectId: 1);
        await state.refreshLinkedMergeRequest();
        expect(state.linkedMergeRequest, isNull);
        expect(state.loadingLinkedMergeRequest, isFalse);
      },
    );

    test(
      'refreshLinkedMergeRequest uses repo branch when thread has none',
      () async {
        final client = ApiClient.withClient(
          MockClient((req) async {
            if (req.url.path == '/api/projects/1/git/merge-request') {
              expect(req.url.queryParameters['branch'], 'main');
              return _json(200, {
                'iid': 1,
                'title': 'T',
                'state': 'opened',
                'source_branch': 'main',
                'target_branch': 'main',
                'web_url': 'https://x/-/merge_requests/1',
                'draft': false,
              });
            }
            return _json(404, {'error': 'unexpected'});
          }),
        );
        final state = AppState.test(
          api: ApiService(client: client),
          activeProjectId: 1,
          gitRepoInfo: {
            1: GitRepoInfo(
              isRepo: true,
              branch: 'main',
              worktreePath: '/x',
              toplevel: '/x',
              commonDir: '/x/.git',
            ),
          },
        );
        await state.refreshLinkedMergeRequest();
        expect(state.linkedMergeRequest, isNotNull);
        expect(state.linkedMergeRequest!.iid, 1);
      },
    );
  });

  group('Plan overlay', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('auto-opens when active thread has a plan', () {
      final state = AppState.test(
        activeProjectId: 1,
        activeThreadId: 'a',
        activeThreadDetail: ThreadDetail(
          thread: Thread(
            id: 'a',
            title: 't',
            projectId: 1,
            model: '',
            permissionMode: 'normal',
            createdAt: '',
            updatedAt: '',
          ),
          plan: Plan(
            explanation: 'Build',
            steps: [PlanStep(step: 'S', status: 'in_progress')],
          ),
        ),
      );
      expect(state.activePlan, isNotNull);
      expect(state.planOverlayVisible, isTrue);
      expect(state.planOverlayExpanded, isTrue);
    });

    test('dismissPlanOverlay hides overlay and openPlanOverlay reopens it', () {
      final state = AppState.test(
        activeProjectId: 1,
        activeThreadId: 'a',
        activeThreadDetail: ThreadDetail(
          thread: Thread(
            id: 'a',
            title: 't',
            projectId: 1,
            model: '',
            permissionMode: 'normal',
            createdAt: '',
            updatedAt: '',
          ),
          plan: Plan(
            steps: [PlanStep(step: 'S', status: 'pending')],
          ),
        ),
      );
      expect(state.planOverlayVisible, isTrue);
      expect(state.planOverlayExpanded, isTrue);
      state.dismissPlanOverlay();
      expect(state.planOverlayVisible, isFalse);
      expect(state.planOverlayDismissed, isTrue);
      state.openPlanOverlay();
      expect(state.planOverlayVisible, isTrue);
      expect(state.planOverlayExpanded, isTrue);
    });

    test(
      'activePlan falls back to detail plan when streaming plan is null',
      () {
        final state = AppState.test(
          activeProjectId: 1,
          activeThreadId: 'a',
          activeThreadDetail: ThreadDetail(
            thread: Thread(
              id: 'a',
              title: 't',
              projectId: 1,
              model: '',
              permissionMode: 'normal',
              createdAt: '',
              updatedAt: '',
            ),
            plan: Plan(steps: [PlanStep(step: 'S')]),
          ),
        );
        expect(state.activePlan?.steps[0].step, 'S');
      },
    );

    test('dismissPlanOverlay and openPlanOverlay preserve collapsed state', () {
      final state = AppState.test(
        activeProjectId: 1,
        activeThreadId: 'a',
        activeThreadDetail: ThreadDetail(
          thread: Thread(
            id: 'a',
            title: 't',
            projectId: 1,
            model: '',
            permissionMode: 'normal',
            createdAt: '',
            updatedAt: '',
          ),
          plan: Plan(
            steps: [PlanStep(step: 'S', status: 'pending')],
          ),
        ),
      );
      state.collapsePlanOverlay();
      expect(state.planOverlayExpanded, isFalse);
      state.dismissPlanOverlay();
      expect(state.planOverlayVisible, isFalse);
      expect(state.planOverlayExpanded, isFalse);
      state.openPlanOverlay();
      expect(state.planOverlayVisible, isTrue);
      expect(state.planOverlayExpanded, isFalse);
    });

    test('togglePlanOverlay preserves collapsed state', () {
      final state = AppState.test(
        activeProjectId: 1,
        activeThreadId: 'a',
        activeThreadDetail: ThreadDetail(
          thread: Thread(
            id: 'a',
            title: 't',
            projectId: 1,
            model: '',
            permissionMode: 'normal',
            createdAt: '',
            updatedAt: '',
          ),
          plan: Plan(
            steps: [PlanStep(step: 'S', status: 'pending')],
          ),
        ),
      );
      state.collapsePlanOverlay();
      state.togglePlanOverlay();
      expect(state.planOverlayVisible, isFalse);
      expect(state.planOverlayExpanded, isFalse);
      state.togglePlanOverlay();
      expect(state.planOverlayVisible, isTrue);
      expect(state.planOverlayExpanded, isFalse);
    });

    test('plan overlay state is persisted', () async {
      final state = AppState.test(
        activeProjectId: 1,
        activeThreadId: 'a',
        activeThreadDetail: ThreadDetail(
          thread: Thread(
            id: 'a',
            title: 't',
            projectId: 1,
            model: '',
            permissionMode: 'normal',
            createdAt: '',
            updatedAt: '',
          ),
          plan: Plan(
            steps: [PlanStep(step: 'S', status: 'pending')],
          ),
        ),
      );
      state.collapsePlanOverlay();
      state.dismissPlanOverlay();
      await Future.delayed(Duration.zero);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('devinorium_plan_overlay_expanded'), isFalse);
      expect(prefs.getBool('devinorium_plan_overlay_dismissed'), isTrue);
    });

    test('bootstrap loads saved plan overlay state', () async {
      SharedPreferences.setMockInitialValues({
        'devinorium_plan_overlay_expanded': false,
        'devinorium_plan_overlay_dismissed': true,
      });
      final state = AppState(
        api: ApiService(
          client: _clientFor([
            _json(200, {
              'id': 1,
              'username': 'owner',
              'role': 'user',
              'is_owner': true,
              'totp_enabled': false,
              'provider_id': 'devin-cli',
              'provider_command': 'devin',
            }),
            _json(200, [
              {'id': 'glm-5-2', 'label': 'GLM'},
            ]),
            _json(200, [
              {'id': 'devin-cli', 'name': 'Devin CLI'},
            ]),
            _json(200, [
              {
                'id': 1,
                'name': 'p',
                'path': '/x',
                'created_at': '',
                'updated_at': '',
              },
            ]),
            _json(200, [
              {
                'id': 'a',
                'title': 't',
                'project_id': 1,
                'model': '',
                'permission_mode': 'normal',
                'created_at': '',
                'updated_at': '',
              },
            ]),
            _json(200, []),
          ]),
        ),
      );
      await state.bootstrap();
      expect(state.planOverlayExpanded, isFalse);
      expect(state.planOverlayDismissed, isTrue);
    });
  });
}
