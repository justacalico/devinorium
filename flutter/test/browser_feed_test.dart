import 'dart:async';
import 'dart:convert';

import 'package:async/async.dart';
import 'package:devinorium_frontend/browser/browser_feed.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class _FakeWebSocketSink extends DelegatingStreamSink<dynamic>
    implements WebSocketSink {
  _FakeWebSocketSink(super.sink);

  final sent = <dynamic>[];

  @override
  void add(dynamic event) {
    sent.add(event);
    super.add(event);
  }

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
  late final WebSocketSink sink = _FakeWebSocketSink(_controller.foreign.sink);

  StreamSink<dynamic> get remoteSink => _controller.local.sink;
  _FakeWebSocketSink get sentSink => sink as _FakeWebSocketSink;
}

void main() {
  test('decodes frame messages and tracks live status', () async {
    final channel = _FakeWebSocketChannel();
    final feed = BrowserFeedClient(
      uri: Uri.parse('ws://test/feed'),
      connector: (uri, {token}) => channel,
    );
    addTearDown(feed.dispose);

    expect(feed.status, BrowserFeedStatus.connecting);

    channel.remoteSink.add(
      jsonEncode({
        'type': 'frame',
        'url': 'https://example.com',
        'title': 'Example',
        'data': base64Encode([1, 2, 3]),
      }),
    );
    await pumpEventQueue();

    expect(feed.status, BrowserFeedStatus.live);
    expect(feed.frame.url, 'https://example.com');
    expect(feed.frame.title, 'Example');
    expect(feed.frame.frame, [1, 2, 3]);
  });

  test('metadata-only frame keeps the last image', () async {
    final channel = _FakeWebSocketChannel();
    final feed = BrowserFeedClient(
      uri: Uri.parse('ws://test/feed'),
      connector: (uri, {token}) => channel,
    );
    addTearDown(feed.dispose);

    channel.remoteSink.add(
      jsonEncode({
        'type': 'frame',
        'url': 'https://a.b',
        'title': 'A',
        'data': base64Encode([9]),
      }),
    );
    channel.remoteSink.add(
      jsonEncode({
        'type': 'frame',
        'url': 'https://c.d',
        'title': 'C',
        'data': '',
      }),
    );
    await pumpEventQueue();

    expect(feed.frame.frame, [9]);
    expect(feed.frame.url, 'https://c.d');
    expect(feed.frame.title, 'C');
  });

  test('idle status shows while no frame arrived', () async {
    final channel = _FakeWebSocketChannel();
    final feed = BrowserFeedClient(
      uri: Uri.parse('ws://test/feed'),
      connector: (uri, {token}) => channel,
    );
    addTearDown(feed.dispose);

    channel.remoteSink.add(jsonEncode({'type': 'status', 'state': 'idle'}));
    await pumpEventQueue();

    expect(feed.status, BrowserFeedStatus.idle);
    expect(feed.frame.frame, isNull);
  });

  test('malformed and binary messages are ignored', () async {
    final channel = _FakeWebSocketChannel();
    final feed = BrowserFeedClient(
      uri: Uri.parse('ws://test/feed'),
      connector: (uri, {token}) => channel,
    );
    addTearDown(feed.dispose);

    channel.remoteSink.add('not json');
    channel.remoteSink.add(jsonEncode({'type': 'frame', 'data': '!!!'}));
    channel.remoteSink.add([1, 2, 3]);
    await pumpEventQueue();

    // A frame message with undecodable data still counts as live metadata.
    expect(feed.status, BrowserFeedStatus.live);
    expect(feed.frame.frame, isNull);
  });

  test('never sends anything back over the socket', () async {
    final channel = _FakeWebSocketChannel();
    final feed = BrowserFeedClient(
      uri: Uri.parse('ws://test/feed'),
      connector: (uri, {token}) => channel,
    );
    addTearDown(feed.dispose);

    channel.remoteSink.add(
      jsonEncode({'type': 'frame', 'url': 'u', 'title': 't', 'data': 'aGk='}),
    );
    await pumpEventQueue();

    expect(channel.sentSink.sent, isEmpty);
  });

  test('socket close reconnects after a delay', () async {
    var connects = 0;
    final channels = <_FakeWebSocketChannel>[];
    final feed = BrowserFeedClient(
      uri: Uri.parse('ws://test/feed'),
      connector: (uri, {token}) {
        connects++;
        final c = _FakeWebSocketChannel();
        channels.add(c);
        return c;
      },
    );
    addTearDown(feed.dispose);

    expect(connects, 1);
    channels.last.remoteSink.close();
    expect(feed.status, isNot(BrowserFeedStatus.closed));

    await Future.delayed(const Duration(seconds: 3));
    expect(connects, 2);
  });
}
