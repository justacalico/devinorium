import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:devinorium_frontend/models/composer_mode.dart';
import 'package:devinorium_frontend/models/models.dart';
import 'package:devinorium_frontend/state/app_state.dart';

void main() {
  group('NavigationStore', () {
    test('view, page and user menu reflect updates and notify', () {
      final state = AppState.test();
      addTearDown(state.dispose);

      var calls = 0;
      state.addListener(() => calls++);

      state.setView(AppView.login);
      expect(state.view, AppView.login);

      state.setPage(MainPage.settings);
      expect(state.page, MainPage.settings);

      state.setUserMenuOpen(true);
      expect(state.userMenuOpen, true);

      expect(calls, 3);
    });
  });

  group('CoreStore', () {
    test('global error can be set and cleared', () {
      final state = AppState.test();
      addTearDown(state.dispose);

      var called = false;
      state.addListener(() => called = true);

      state.setGlobalError('boom');
      expect(state.globalError, 'boom');
      expect(called, true);

      state.clearGlobalError();
      expect(state.globalError, '');
    });
  });

  group('AuthStore', () {
    test('user, users and auth flags are exposed', () {
      final user = User(
        id: 1,
        username: 'owner',
        role: 'owner',
        totpEnabled: false,
        isOwner: true,
        disabled: false,
        createdAt: '',
        providerId: '',
        providerCommand: '',
      );
      final state = AppState.test(user: user, users: [user]);
      addTearDown(state.dispose);

      expect(state.user, user);
      expect(state.users, [user]);
      expect(state.isOwner, true);

      state.setLoginError('bad');
      expect(state.loginError, 'bad');

      state.setShowTotpField(true);
      expect(state.showTotpField, true);
    });
  });

  group('ProjectStore', () {
    test('project defaults and dialog openers work', () async {
      final state = AppState.test();
      addTearDown(state.dispose);

      expect(state.projects, isEmpty);
      expect(state.hasMoreProjects, false);

      await state.openNewProjectDialog();
      expect(state.dialog, DialogKind.newProject);

      state.closeDialog();
      expect(state.dialog, DialogKind.none);
    });
  });

  group('ThreadListStore', () {
    test('thread list defaults and active thread are exposed', () {
      final state = AppState.test();
      addTearDown(state.dispose);

      expect(state.threads, isEmpty);
      expect(state.groups, isEmpty);
      expect(state.activeThreadId, isNull);
      expect(state.hasMoreThreads, false);
      expect(state.hasMoreProjectThreads(1), false);
      expect(state.sending, false);
      expect(state.activeThreadDetail, isNull);
    });
  });

  group('ComposerStore', () {
    test('composer text and mode update and notify', () {
      final state = AppState.test();
      addTearDown(state.dispose);

      var calls = 0;
      state.addListener(() => calls++);

      state.setComposerText('hello');
      expect(state.composerText, 'hello');

      state.setComposerMode(ComposerMode.ask);
      expect(state.composerMode, ComposerMode.ask);

      expect(calls, 2);
    });
  });

  group('AttachmentStore', () {
    test('attachments can be added, removed and cleared', () {
      final state = AppState.test();
      addTearDown(state.dispose);

      final file = (
        filename: 'a.txt',
        mime: 'text/plain',
        bytes: Uint8List(0),
      );

      state.addAttachments([file]);
      expect(state.attachments.length, 1);

      state.removeAttachment(0);
      expect(state.attachments, isEmpty);

      state.addAttachments([file, file]);
      state.clearAttachments();
      expect(state.attachments, isEmpty);
    });
  });

  group('ModelStore', () {
    test('models and selected values are exposed', () {
      final state = AppState.test();
      addTearDown(state.dispose);

      expect(state.models, isEmpty);
      expect(state.providers, isEmpty);

      state.setSelectedModel('gpt-4');
      expect(state.selectedModel, 'gpt-4');

      state.setSelectedPermission('owner');
      expect(state.selectedPermission, 'owner');
    });
  });

  group('PlanOverlayStore', () {
    test('plan overlay can be opened and dismissed', () {
      final state = AppState.test();
      addTearDown(state.dispose);

      expect(state.planOverlayVisible, false);

      state.openPlanOverlay();
      expect(state.planOverlayVisible, true);
      expect(state.planOverlayDismissed, false);

      state.dismissPlanOverlay();
      expect(state.planOverlayVisible, false);
      expect(state.planOverlayDismissed, true);
    });
  });

  group('FilesPanelStore', () {
    test('files panel state defaults are exposed', () {
      final state = AppState.test();
      addTearDown(state.dispose);

      expect(state.filesPanelOpen, false);
      expect(state.filesEntries, isEmpty);
      expect(state.hasMoreFiles, true);
      expect(state.isLoadingMoreFiles, false);
    });
  });

  group('HealthCheckStore', () {
    test('connection status is exposed', () {
      final state = AppState.test(
        connectionStatus: ConnectionStatus.disconnected,
      );
      addTearDown(state.dispose);

      expect(state.connectionStatus, ConnectionStatus.disconnected);
    });
  });

  group('GitStore', () {
    test('git repo info, branches and worktrees are exposed', () {
      final info = GitRepoInfo();
      final state = AppState.test(gitRepoInfo: {1: info});
      addTearDown(state.dispose);

      expect(state.gitRepoInfo(1), info);
      expect(state.gitBranches(1), isEmpty);
      expect(state.gitWorktrees(1), isEmpty);
    });
  });

  group('GitRefreshStore', () {
    test('git connections default and stop does not throw', () {
      final state = AppState.test();
      addTearDown(state.dispose);

      expect(state.gitConnections, isEmpty);
      expect(state.stopGitRefresh, returnsNormally);
    });
  });

  group('DialogStore', () {
    test('dialog can be closed', () {
      final state = AppState.test(dialog: DialogKind.cloneRepo);
      addTearDown(state.dispose);

      expect(state.dialog, DialogKind.cloneRepo);

      state.closeDialog();
      expect(state.dialog, DialogKind.none);
      expect(state.mergeRequestUrl, isNull);
      expect(state.issueUrl, isNull);
    });
  });

  group('SettingsStore', () {
    test('settings can be updated', () {
      final state = AppState.test();
      addTearDown(state.dispose);

      state.setSettingsTopicIndex(2);
      expect(state.settingsTopicIndex, 2);

      state.setLanguage('zh');
      expect(state.locale, const Locale('zh'));

      state.setNotificationsEnabled(true);
      expect(state.notificationsEnabled, true);
    });
  });
}
