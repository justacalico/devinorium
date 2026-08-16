import 'package:devinorium_frontend/utils/link_opener.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/url_launcher');
  final launched = <String>[];

  setUp(() {
    launched.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'canLaunch':
          return true;
        case 'launch':
          final args = call.arguments as Map<dynamic, dynamic>;
          launched.add(args['url'] as String);
          return true;
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    launched.clear();
  });

  test('isOpenableLink only allows http and https', () {
    expect(isOpenableLink('https://example.com'), isTrue);
    expect(isOpenableLink('http://example.com'), isTrue);
    expect(isOpenableLink('javascript:alert(1)'), isFalse);
    expect(isOpenableLink('mailto:a@b.com'), isFalse);
    expect(isOpenableLink(null), isFalse);
    expect(isOpenableLink(''), isFalse);
  });

  test('openLink launches valid https urls', () async {
    await openLink('https://example.com');
    expect(launched, ['https://example.com']);
  });

  test('openLink ignores non-http schemes', () async {
    await openLink('javascript:alert(1)');
    await openLink('');
    await openLink('ftp://example.com');
    expect(launched, isEmpty);
  });
}
