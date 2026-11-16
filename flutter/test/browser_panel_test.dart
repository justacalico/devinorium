import 'dart:async';
import 'dart:convert';

import 'package:async/async.dart';
import 'package:devinorium_frontend/browser/browser_feed.dart';
import 'package:devinorium_frontend/browser/browser_panel.dart';
import 'package:devinorium_frontend/browser/browser_store.dart';
import 'package:devinorium_frontend/state/app_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class _FakeWebSocketSink extends DelegatingStreamSink<dynamic>
    implements WebSocketSink {
  _FakeWebSocketSink(super.sink);

  @override
  Future close([int? closeCode, String? closeReason]) => super.close();
}

class _FakeWebSocketChannel extends StreamChannelMixin<dynamic>
    implements WebSocketChannel {
  final _controller = StreamChannelController<dynamic>(
    sync: true,
    allowForeignErrors: false,
  );

  @override
  String? get protocol => null;

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  Future<void> get ready => Future.value();

  @override
  Stream<dynamic> get stream => _controller.foreign.stream;

  @override
  late final WebSocketSink sink = _FakeWebSocketSink(
    _controller.foreign.sink,
  );

  StreamSink<dynamic> get remoteSink => _controller.local.sink;
}

// A 1x1 PNG so Image.memory decodes a real image in tests.
const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

class _Harness {
  final store = BrowserPanelStore();
  final channels = <_FakeWebSocketChannel>[];
  final uris = <Uri>[];

  BrowserFeedClient makeFeed(Uri uri, String? token) {
    uris.add(uri);
    final channel = _FakeWebSocketChannel();
    channels.add(channel);
    return BrowserFeedClient(
      uri: uri,
      token: token,
      connector: (_, {token}) => channel,
    );
  }
}

Widget _app(AppState state, _Harness h) => MaterialApp(
  home: ChangeNotifierProvider<AppState>.value(
    value: state,
    child: Scaffold(
      body: BrowserPanel(store: h.store, feedFactory: h.makeFeed),
    ),
  ),
);

void main() {
  testWidgets('renders nothing while the store is closed', (tester) async {
    final state = AppState.test(
      activeThreadId: 't1',
      webAccessEnabled: true,
    );
    final h = _Harness();
    addTearDown(state.dispose);
    addTearDown(h.store.dispose);

    await tester.pumpWidget(_app(state, h));
    await tester.pumpAndSettle();

    expect(find.byType(BrowserPanel), findsOneWidget);
    expect(find.byIcon(Icons.public), findsNothing);
    expect(h.channels, isEmpty);
  });

  testWidgets('web access off shows its empty state and never connects', (
    tester,
  ) async {
    final state = AppState.test(activeThreadId: 't1');
    final h = _Harness()..store.setOpen(true);
    addTearDown(state.dispose);
    addTearDown(h.store.dispose);

    await tester.pumpWidget(_app(state, h));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Web access is off. Enable it in Settings to watch the agent browse.',
      ),
      findsOneWidget,
    );
    expect(h.channels, isEmpty);
  });

  testWidgets('idle feed shows the empty state, frame shows the image', (
    tester,
  ) async {
    final state = AppState.test(
      activeThreadId: 't1',
      webAccessEnabled: true,
    );
    final h = _Harness()..store.setOpen(true);
    addTearDown(state.dispose);
    addTearDown(h.store.dispose);

    await tester.pumpWidget(_app(state, h));
    await tester.pumpAndSettle();

    expect(h.channels, hasLength(1));
    expect(h.uris.single.path, '/api/threads/t1/browser/ws');
    expect(
      find.text("The agent's browser shows up here while it browses."),
      findsOneWidget,
    );

    h.channels.single.remoteSink.add(
      jsonEncode({
        'type': 'frame',
        'url': 'https://example.com/page',
        'title': 'Example',
        'data': _png,
      }),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('browserFrame')), findsOneWidget);
    expect(find.textContaining('Example'), findsOneWidget);
    expect(find.textContaining('https://example.com/page'), findsOneWidget);
    expect(
      find.text("The agent's browser shows up here while it browses."),
      findsNothing,
    );
  });

  testWidgets('closing the panel drops the feed and hides the view', (
    tester,
  ) async {
    final state = AppState.test(
      activeThreadId: 't1',
      webAccessEnabled: true,
    );
    final h = _Harness()..store.setOpen(true);
    addTearDown(state.dispose);
    addTearDown(h.store.dispose);

    await tester.pumpWidget(_app(state, h));
    await tester.pumpAndSettle();
    expect(h.channels, hasLength(1));

    await tester.tap(find.byTooltip('Hide browser'));
    await tester.pumpAndSettle();

    expect(h.store.open, isFalse);
    expect(find.byIcon(Icons.public), findsNothing);
  });
}
