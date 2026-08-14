import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/api/api_service.dart';
import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/state/app_state.dart';
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
  return ApiClient.withClient(MockClient((req) async {
    if (index >= responses.length) {
      return _json(404, {'error': 'unexpected request to ${req.url.path}'});
    }
    return responses[index++];
  }));
}

/// [ApiService] whose streaming send can be replaced by a test stream.
class _StreamableApiService extends ApiService {
  Stream<SseEvent> Function()? streamBuilder;

  _StreamableApiService(ApiClient client) : super(client: client);

  @override
  Stream<SseEvent> sendMessageStream({
    required String threadId,
    required String prompt,
    List<({String filename, String mime, Uint8List bytes})> attachments = const [],
  }) {
    return streamBuilder?.call() ?? Stream.empty();
  }
}

void main() {
  group('Basic state mutations', () {
    test('attachments can be added and removed', () {
      final state = AppState.test();
      final file = (filename: 'a.txt', mime: 'text/plain', bytes: Uint8List.fromList([1]));
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
        api: ApiService(client: _clientFor([
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
            {'id': 1, 'name': 'p', 'path': '/x', 'created_at': '', 'updated_at': ''},
          ]),
          _json(200, [
            {'id': 'a', 'title': 't', 'project_id': 1, 'model': '', 'permission_mode': 'normal', 'created_at': '', 'updated_at': ''},
          ]),
          _json(200, []),
        ])),
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
        api: ApiService(client: _clientFor([http.Response('unauthorized', 401)])),
      );
      await state.bootstrap();
      expect(state.view, AppView.login);
    });

    test('doLogin navigates to app and loads data', () async {
      final state = AppState(
        api: ApiService(client: _clientFor([
          _json(200, {'ok': true, 'totp_required': false, 'username': 'owner'}),
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
            {'id': 1, 'name': 'p', 'path': '/x', 'created_at': '', 'updated_at': ''},
          ]),
          _json(200, []),
          _json(200, []),
        ])),
      );

      await state.doLogin(username: 'owner', password: 'pw');
      expect(state.view, AppView.app);
      expect(state.user?.username, 'owner');
      expect(state.loginError, isEmpty);
    });

    test('doLogin shows TOTP field when required', () async {
      final state = AppState(
        api: ApiService(client: _clientFor([
          _json(200, {'ok': true, 'totp_required': true, 'username': 'owner'}),
        ])),
      );
      await state.doLogin(username: 'owner', password: 'pw');
      expect(state.showTotpField, isTrue);
      expect(state.view, AppView.login);
      expect(state.loginError, contains('TOTP'));
    });

    test('doLogin sets error on failure', () async {
      final state = AppState(
        api: ApiService(client: _clientFor([
          _json(401, {'error': 'bad password'}),
        ])),
      );
      await state.doLogin(username: 'owner', password: 'pw');
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
        api: ApiService(client: _clientFor([
          _json(200, [
            {'id': 'a', 'title': 't', 'project_id': 1, 'model': '', 'permission_mode': 'normal', 'created_at': '', 'updated_at': ''},
          ]),
          _json(200, []),
        ])),
      );
      final base = AppState.test(
        api: state.api,
        projects: [Project(id: 1, name: 'p', path: '/x', createdAt: '', updatedAt: '')],
      );
      base.setView(AppView.app);
      await base.selectProject(1);
      expect(base.activeProjectId, 1);
      expect(base.threads, hasLength(1));
      expect(base.page, MainPage.threads);
    });

    test('createProject adds to list and selects it', () async {
      final state = AppState(
        api: ApiService(client: _clientFor([
          _json(200, {'id': 2, 'name': 'p2', 'path': '/y', 'created_at': '', 'updated_at': ''}),
          _json(200, []),
          _json(200, []),
        ])),
      );
      final base = AppState.test(
        api: state.api,
        projects: [Project(id: 1, name: 'p1', path: '/x', createdAt: '', updatedAt: '')],
      );
      base.setView(AppView.app);
      await base.createProject(name: 'p2', path: '/y');
      expect(base.projects, hasLength(2));
      expect(base.activeProjectId, 2);
    });

    test('deleteProject removes project and selects another', () async {
      final state = AppState(
        api: ApiService(client: _clientFor([
          _json(200, {}),
          _json(200, []),
          _json(200, []),
        ])),
      );
      final base = AppState.test(
        api: state.api,
        projects: [
          Project(id: 1, name: 'p1', path: '/x', createdAt: '', updatedAt: ''),
          Project(id: 2, name: 'p2', path: '/y', createdAt: '', updatedAt: ''),
        ],
        activeProjectId: 1,
        activeProjectPath: '/x',
      );
      base.setView(AppView.app);
      await base.deleteProject(1);
      expect(base.projects, hasLength(1));
      expect(base.activeProjectId, 2);
    });

    test('openThread loads detail and updates active project', () async {
      final state = AppState(
        api: ApiService(client: _clientFor([
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
        ])),
      );
      final base = AppState.test(
        api: state.api,
        projects: [Project(id: 1, name: 'p', path: '/x', createdAt: '', updatedAt: '')],
      );
      await base.openThread('a');
      expect(base.activeThreadId, 'a');
      expect(base.activeThreadDetail, isNotNull);
      expect(base.selectedModel, 'glm-5-2');
      expect(base.activeProjectId, 1);
    });

    test('createNewThread requires a project', () async {
      final state = AppState.test();
      await state.createNewThread();
      expect(state.globalError, contains('Select a project first'));
    });

    test('deleteThread clears active thread', () async {
      final state = AppState(
        api: ApiService(client: _clientFor([
          _json(200, {}),
          _json(200, []),
          _json(200, []),
        ])),
      );
      final base = AppState.test(api: state.api, activeThreadId: 'a');
      await base.deleteThread('a');
      expect(base.activeThreadId, isNull);
    });

    test('saveThreadSettings updates active thread detail', () async {
      final state = AppState(
        api: ApiService(client: _clientFor([
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
        ])),
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
        api: ApiService(client: _clientFor([
          _json(200, {
            'id': 1,
            'username': 'owner',
            'role': 'user',
            'is_owner': true,
            'totp_enabled': false,
            'provider_id': 'devin-cli',
            'provider_command': 'devin-cli',
          }),
        ])),
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
        api: ApiService(client: _clientFor([
          _json(400, {'error': 'not found'}),
        ])),
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

  group('Files', () {
    test('openFilesPanel loads entries', () async {
      final state = AppState(
        api: ApiService(client: _clientFor([
          _json(200, [
            {'name': 'a.txt', 'is_dir': false, 'size': 1},
          ]),
        ])),
      );
      final base = AppState.test(api: state.api, activeProjectId: 1);
      await base.openFilesPanel();
      expect(base.filesPanelOpen, isTrue);
      expect(base.filesEntries, hasLength(1));
      expect(base.filesError, isEmpty);
    });

    test('navigateFilesInto updates path and reloads', () async {
      final state = AppState(
        api: ApiService(client: _clientFor([
          _json(200, [
            {'name': 'b.txt', 'is_dir': false, 'size': 2},
          ]),
        ])),
      );
      final base = AppState.test(api: state.api, activeProjectId: 1, filesPath: []);
      await base.navigateFilesInto('dir');
      expect(base.filesPath, ['dir']);
      expect(base.filesEntries, hasLength(1));
    });

    test('mkdir creates directory and reloads', () async {
      final state = AppState(
        api: ApiService(client: _clientFor([
          _json(200, {}),
          _json(200, []),
        ])),
      );
      final base = AppState.test(api: state.api, activeProjectId: 1);
      await base.mkdir('newdir');
      expect(base.filesError, isEmpty);
    });

    test('deleteFile removes and reloads', () async {
      final state = AppState(
        api: ApiService(client: _clientFor([
          _json(200, {}),
          _json(200, []),
        ])),
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

      state.addListener(() {
        if (!state.sending && state.streamingText == null) {
          if (!completer.isCompleted) completer.complete();
        }
      });

      await state.sendMessage();
      controller.add(SseEvent('chunk', 'world'));
      controller.add(SseEvent('done', '{"role":"assistant","content":"hello world"}'));

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
    });
  });

  group('TOTP, dialog and accounts', () {
    test('openTotpSetup sets secret and dialog', () async {
      final state = AppState(
        api: ApiService(client: _clientFor([
          _json(200, {'secret': 's', 'otpauth_uri': 'otpauth://x'}),
        ])),
      );
      await state.openTotpSetup();
      expect(state.totpSecret, 's');
      expect(state.dialog, DialogKind.totpSetup);
    });

    test('verifyTotp closes dialog and refreshes user', () async {
      final state = AppState(
        api: ApiService(client: _clientFor([
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
        ])),
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
        api: ApiService(client: _clientFor([
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
        ])),
      );
      await state.loadUsers();
      expect(state.users, hasLength(1));
      expect(state.users.first.username, 'owner');
      expect(state.users.first.isOwner, isTrue);
    });

    test('createUser reloads users', () async {
      final state = AppState(
        api: ApiService(client: _clientFor([
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
        ])),
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
        (await SharedPreferences.getInstance()).getString('devinorium_language'),
        'en-GB',
      );

      final restored = AppState.test();
      await restored.bootstrap();
      expect(restored.locale, const Locale('en-GB'));
    });
  });
}
