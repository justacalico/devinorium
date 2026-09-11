import 'dart:async';

import 'package:devinorium_frontend/api/api_service.dart';
import 'package:devinorium_frontend/terminal/terminal_session.dart';
import 'package:devinorium_frontend/terminal/terminal_store.dart';
import 'package:flutter_test/flutter_test.dart';

TerminalStore _store({
  String? Function()? activeThreadId,
  TerminalSessionFactory? sessionFactory,
}) => TerminalStore(
  api: () => ApiService(),
  activeThreadId: activeThreadId,
  sessionFactory: sessionFactory,
);

TerminalSessionFactory _fakeFactory({void Function(String? threadId)? onCall}) {
  var callCount = 0;
  return ({
    required ApiService api,
    required String? threadId,
    required bool local,
  }) async {
    callCount++;
    onCall?.call(threadId);
    return TerminalSession(id: 's-$callCount', isLocal: local);
  };
}

void main() {
  group('TerminalStore', () {
    test('addSession auto-creates a tab and appends the session', () async {
      final store = _store(sessionFactory: _fakeFactory());
      addTearDown(store.dispose);

      await store.addSession(local: false);

      expect(store.tabs, hasLength(1));
      expect(store.activeTabIndex, 0);
      expect(store.tabs.single.sessions.single.id, 's-1');
      expect(store.busy, isFalse);
    });

    test('passes the current active thread to the factory', () async {
      var current = 't1';
      final seen = <String?>[];
      final store = _store(
        activeThreadId: () => current,
        sessionFactory: _fakeFactory(onCall: seen.add),
      );
      addTearDown(store.dispose);

      await store.addSession(local: false);
      current = 't2';
      await store.addSession(local: false);

      expect(seen, ['t1', 't2']);
      // Both sessions live in the same global workspace.
      expect(store.tabs.single.sessions, hasLength(2));
    });

    test('works without an active thread', () async {
      final seen = <String?>[];
      final store = _store(sessionFactory: _fakeFactory(onCall: seen.add));
      addTearDown(store.dispose);

      await store.addSession(local: false);

      expect(seen, [isNull]);
      expect(store.tabs.single.sessions, hasLength(1));
    });

    test('factory errors propagate and clear busy', () async {
      final store = _store(
        sessionFactory:
            ({
              required ApiService api,
              required String? threadId,
              required bool local,
            }) async => throw StateError('nope'),
      );
      addTearDown(store.dispose);

      await expectLater(store.addSession(local: false), throwsStateError);
      expect(store.busy, isFalse);
      expect(store.tabs.single.sessions, isEmpty);
    });

    test('concurrent addSession calls are ignored while busy', () async {
      final gate = Completer<void>();
      var calls = 0;
      final store = _store(
        sessionFactory:
            ({
              required ApiService api,
              required String? threadId,
              required bool local,
            }) async {
              calls++;
              await gate.future;
              return TerminalSession(id: 's-$calls', isLocal: local);
            },
      );
      addTearDown(store.dispose);

      final first = store.addSession(local: false);
      final second = store.addSession(local: false);
      gate.complete();
      await first;
      await second;

      expect(calls, 1);
      expect(store.tabs.single.sessions, hasLength(1));
    });

    test('tab management follows browser semantics', () async {
      final store = _store(sessionFactory: _fakeFactory());
      addTearDown(store.dispose);

      store.addTab();
      store.addTab();
      expect(store.tabs, hasLength(2));
      expect(store.activeTabIndex, 1);

      store.setActiveTab(0);
      expect(store.activeTabIndex, 0);
      store.setActiveTab(9);
      expect(store.activeTabIndex, 0);

      store.removeTab(store.tabs[1]);
      expect(store.tabs, hasLength(1));
      expect(store.activeTabIndex, 0);

      store.removeTab(store.tabs.single);
      expect(store.tabs, isEmpty);
      expect(store.activeTabIndex, 0);
    });

    test('removeSession disposes the session and notifies', () async {
      final store = _store(sessionFactory: _fakeFactory());
      addTearDown(store.dispose);

      await store.addSession(local: false);
      final session = store.tabs.single.sessions.single;

      var notified = 0;
      store.addListener(() => notified++);
      store.removeSession(session);

      expect(notified, 1);
      expect(store.tabs.single.sessions, isEmpty);
      await expectLater(session.completed, completes);
    });

    test('removeTab disposes every session in the tab', () async {
      final store = _store(sessionFactory: _fakeFactory());
      addTearDown(store.dispose);

      await store.addSession(local: false);
      await store.addSession(local: false);
      final tab = store.tabs.single;
      final sessions = List.of(tab.sessions);

      store.removeTab(tab);

      expect(store.tabs, isEmpty);
      for (final session in sessions) {
        await expectLater(session.completed, completes);
      }
    });

    test('open state and height are shared', () {
      final store = _store();
      addTearDown(store.dispose);

      expect(store.open, isFalse);
      store.toggleOpen();
      expect(store.open, isTrue);
      store.setOpen(false);
      expect(store.open, isFalse);

      expect(store.height, TerminalStore.defaultHeight);
      store.setHeight(400);
      expect(store.height, 400);
      store.setHeight(10);
      expect(store.height, TerminalStore.minHeight);
    });

    test('clear kills all sessions and closes the panel', () async {
      final store = _store(sessionFactory: _fakeFactory());
      addTearDown(store.dispose);

      store.setOpen(true);
      await store.addSession(local: false);
      final session = store.tabs.single.sessions.single;

      store.clear();

      expect(store.tabs, isEmpty);
      expect(store.open, isFalse);
      await expectLater(session.completed, completes);
    });

    test('dispose kills all sessions', () async {
      final store = _store(sessionFactory: _fakeFactory());

      await store.addSession(local: false);
      final session = store.tabs.single.sessions.single;

      store.dispose();

      expect(store.tabs, isEmpty);
      await expectLater(session.completed, completes);
    });
  });
}
