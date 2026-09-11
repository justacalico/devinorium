import 'dart:convert';

import 'package:devinorium_frontend/api/api_client.dart';
import 'package:devinorium_frontend/api/api_service.dart';
import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

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

ApiService _serviceFor(ApiClient client) => ApiService(client: client);

void main() {
  final project = Project(id: 1, name: 'p', path: '/x', createdAt: '', updatedAt: '');

  group('AppMode', () {
    test('defaults to agents', () {
      final state = AppState.test();
      expect(state.appMode, AppMode.agents);
    });

    test('can switch to editor', () {
      final state = AppState.test();
      state.setAppMode(AppMode.editor);
      expect(state.appMode, AppMode.editor);
    });

    test('switching to editor opens files panel and shows threads page', () {
      final state = AppState.test();
      state.setPage(MainPage.settings);
      state.setAppMode(AppMode.editor);

      expect(state.appMode, AppMode.editor);
      expect(state.page, MainPage.threads);
      expect(state.filesPanelOpen, isTrue);
    });

    test('switching to agents closes files panel and shows threads page', () {
      final state = AppState.test();
      state.setAppMode(AppMode.editor);
      expect(state.filesPanelOpen, isTrue);

      state.setPage(MainPage.settings);
      state.setAppMode(AppMode.agents);

      expect(state.appMode, AppMode.agents);
      expect(state.page, MainPage.threads);
      expect(state.filesPanelOpen, isFalse);
    });

    test('switching to the same mode is a no-op', () {
      final state = AppState.test();
      state.setAppMode(AppMode.editor);
      expect(state.filesPanelOpen, isTrue);

      state.setAppMode(AppMode.editor);
      expect(state.filesPanelOpen, isTrue);
    });

    test('no-op mode switch preserves page and panel state', () {
      final state = AppState.test();
      state.setAppMode(AppMode.editor);
      state.setPage(MainPage.settings);

      state.setAppMode(AppMode.editor);

      expect(state.appMode, AppMode.editor);
      expect(state.page, MainPage.settings);
      expect(state.filesPanelOpen, isTrue);
    });
  });

  group('Editor store', () {
    test('openEditorFile adds a tab and loads content', () async {
      final client = _clientFor([
        _json(200, {
          'path': '/x/a.txt',
          'mime': 'text/plain',
          'size': 5,
          'base64': '',
          'text': 'hello',
          'sha256': 'abc',
        }),
      ]);
      final state = AppState.test(
        api: _serviceFor(client),
        projects: [project],
        activeProjectId: 1,
      );

      await state.openEditorFile('a.txt');

      expect(state.editorTabs.length, 1);
      expect(state.activeEditorPath, 'a.txt');
      final tab = state.activeEditorTab!;
      expect(tab.loading, isFalse);
      expect(tab.text, 'hello');
      expect(tab.dirty, isFalse);
      expect(tab.content?.sha256, 'abc');
    });

    test('setEditorTabText tracks dirty state', () async {
      final client = _clientFor([
        _json(200, {
          'path': '/x/a.txt',
          'mime': 'text/plain',
          'size': 5,
          'base64': '',
          'text': 'hello',
          'sha256': 'abc',
        }),
      ]);
      final state = AppState.test(
        api: _serviceFor(client),
        projects: [project],
        activeProjectId: 1,
      );
      await state.openEditorFile('a.txt');
      final tab = state.activeEditorTab!;
      state.setEditorTabText(tab.path, 'changed');

      final updated = state.activeEditorTab!;
      expect(updated.dirty, isTrue);
      expect(state.hasDirtyEditorTabs, isTrue);
    });

    test('saveEditorTab writes and clears dirty', () async {
      final client = _clientFor([
        _json(200, {
          'path': '/x/a.txt',
          'mime': 'text/plain',
          'size': 5,
          'base64': '',
          'text': 'hello',
          'sha256': 'abc',
        }),
        _json(200, {
          'path': '/x/a.txt',
          'mime': 'text/plain',
          'size': 7,
          'base64': '',
          'text': 'changed',
          'sha256': 'def',
        }),
      ]);
      final state = AppState.test(
        api: _serviceFor(client),
        projects: [project],
        activeProjectId: 1,
      );
      await state.openEditorFile('a.txt');
      final tab = state.activeEditorTab!;
      state.setEditorTabText(tab.path, 'changed');

      await state.saveEditorTab(tab.path);

      final saved = state.activeEditorTab!;
      expect(saved.dirty, isFalse);
      expect(saved.content?.sha256, 'def');
      expect(saved.text, 'changed');
    });

    test('saveEditorTab handles conflict', () async {
      final client = _clientFor([
        _json(200, {
          'path': '/x/a.txt',
          'mime': 'text/plain',
          'size': 5,
          'base64': '',
          'text': 'hello',
          'sha256': 'abc',
        }),
        _json(409, {
          'error': 'conflict',
          'current': {
            'path': '/x/a.txt',
            'mime': 'text/plain',
            'size': 4,
            'base64': '',
            'text': 'disk',
            'sha256': 'xyz',
          },
        }),
      ]);
      final state = AppState.test(
        api: _serviceFor(client),
        projects: [project],
        activeProjectId: 1,
      );
      await state.openEditorFile('a.txt');
      final tab = state.activeEditorTab!;
      state.setEditorTabText(tab.path, 'changed');

      await state.saveEditorTab(tab.path);

      final saved = state.activeEditorTab!;
      expect(saved.error, isNotNull);
      expect(saved.content?.sha256, 'xyz');
    });

    test('saveEditorTab keeps user text and recomputes dirty', () async {
      final client = _clientFor([
        _json(200, {
          'path': '/x/a.txt',
          'mime': 'text/plain',
          'size': 5,
          'base64': '',
          'text': 'hello',
          'sha256': 'abc',
        }),
        _json(200, {
          'path': '/x/a.txt',
          'mime': 'text/plain',
          'size': 6,
          'base64': '',
          'text': 'server',
          'sha256': 'def',
        }),
      ]);
      final state = AppState.test(
        api: _serviceFor(client),
        projects: [project],
        activeProjectId: 1,
      );
      await state.openEditorFile('a.txt');
      final tab = state.activeEditorTab!;
      state.setEditorTabText(tab.path, 'user');

      await state.saveEditorTab(tab.path);

      final saved = state.activeEditorTab!;
      expect(saved.text, 'user');
      expect(saved.content?.text, 'server');
      expect(saved.dirty, isTrue);
    });

    test('saveEditorTab skips binary files', () async {
      final client = _clientFor([
        _json(200, {
          'path': '/x/a.bin',
          'mime': 'application/octet-stream',
          'size': 4,
          'base64': 'AAAAAA==',
          'text': null,
          'sha256': 'abc',
        }),
      ]);
      final state = AppState.test(
        api: _serviceFor(client),
        projects: [project],
        activeProjectId: 1,
      );
      await state.openEditorFile('a.bin');

      // Should not try to write and consume another response.
      await state.saveEditorTab('a.bin');

      final saved = state.activeEditorTab!;
      expect(saved.dirty, isFalse);
      expect(saved.content?.text, isNull);
    });

    test('closeAllEditorTabs clears tabs', () async {
      final client = _clientFor([
        _json(200, {
          'path': '/x/a.txt',
          'mime': 'text/plain',
          'size': 1,
          'base64': '',
          'text': 'a',
          'sha256': 'a',
        }),
      ]);
      final state = AppState.test(
        api: _serviceFor(client),
        projects: [project],
        activeProjectId: 1,
      );
      await state.openEditorFile('a.txt');

      state.closeAllEditorTabs();

      expect(state.editorTabs, isEmpty);
      expect(state.activeEditorPath, isNull);
    });

    test('closeEditorTab switches active to another tab', () async {
      final client = _clientFor([
        _json(200, {
          'path': '/x/a.txt',
          'mime': 'text/plain',
          'size': 1,
          'base64': '',
          'text': 'a',
          'sha256': 'a',
        }),
        _json(200, {
          'path': '/x/b.txt',
          'mime': 'text/plain',
          'size': 1,
          'base64': '',
          'text': 'b',
          'sha256': 'b',
        }),
      ]);
      final state = AppState.test(
        api: _serviceFor(client),
        projects: [project],
        activeProjectId: 1,
      );
      await state.openEditorFile('/x/a.txt');
      state.setEditorTabText('/x/a.txt', 'changed');
      await state.openEditorFile('/x/b.txt');

      expect(state.editorTabs.length, 2);
      expect(state.activeEditorPath, '/x/b.txt');
      state.closeEditorTab('/x/b.txt');

      expect(state.editorTabs.length, 1);
      expect(state.activeEditorPath, '/x/a.txt');
    });

    test('openEditorFile replaces an unmodified preview tab', () async {
      final client = _clientFor([
        _json(200, {
          'path': '/x/a.txt',
          'mime': 'text/plain',
          'size': 1,
          'base64': '',
          'text': 'a',
          'sha256': 'a',
        }),
        _json(200, {
          'path': '/x/b.txt',
          'mime': 'text/plain',
          'size': 1,
          'base64': '',
          'text': 'b',
          'sha256': 'b',
        }),
      ]);
      final state = AppState.test(
        api: _serviceFor(client),
        projects: [project],
        activeProjectId: 1,
      );
      await state.openEditorFile('/x/a.txt');
      await state.openEditorFile('/x/b.txt');

      expect(state.editorTabs.length, 1);
      expect(state.activeEditorPath, '/x/b.txt');
    });

    test('openEditorFileNewTab keeps an unmodified preview tab', () async {
      final client = _clientFor([
        _json(200, {
          'path': '/x/a.txt',
          'mime': 'text/plain',
          'size': 1,
          'base64': '',
          'text': 'a',
          'sha256': 'a',
        }),
        _json(200, {
          'path': '/x/b.txt',
          'mime': 'text/plain',
          'size': 1,
          'base64': '',
          'text': 'b',
          'sha256': 'b',
        }),
      ]);
      final state = AppState.test(
        api: _serviceFor(client),
        projects: [project],
        activeProjectId: 1,
      );
      await state.openEditorFile('/x/a.txt');
      await state.openEditorFileNewTab('/x/b.txt');

      expect(state.editorTabs.length, 2);
      expect(state.activeEditorPath, '/x/b.txt');
    });

    test('toggle panels updates state', () {
      final state = AppState.test();
      expect(state.agentPanelOpen, isTrue);
      expect(state.agentPanelUserSet, isFalse);
      expect(state.terminalStore.open, isFalse);
      state.setAgentPanelOpen(false);
      state.terminalStore.setOpen(true);
      expect(state.agentPanelOpen, isFalse);
      expect(state.agentPanelUserSet, isTrue);
      expect(state.terminalStore.open, isTrue);
    });
  });
}
