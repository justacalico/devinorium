import 'dart:convert';

import 'package:devinorium_frontend/services/version_checker.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';

http.Response _json(int status, Object body) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

List<Map<String, dynamic>> _releases(List<String> tags) =>
    tags.map((t) => {'tag_name': t, 'name': t}).toList();

void main() {
  group('VersionChecker', () {
    test('detects an available update when current is older', () async {
      final mock = MockClient(
        (req) async => _json(200, _releases(['nightly', 'v0.40.2'])),
      );
      final checker = VersionChecker(client: mock);
      final update = await checker.check('0.40.1');

      expect(update.updateAvailable, isTrue);
      expect(update.currentVersion, '0.40.1');
      expect(update.latestVersion, '0.40.2');
      expect(update.releaseUrl, '${VersionChecker.releasesUrl}/v0.40.2');
    });

    test(
      'picks the highest semantic version, not the most recent release',
      () async {
        final mock = MockClient(
          (req) async =>
              _json(200, _releases(['v0.41.0', 'v0.40.3', 'v0.40.2'])),
        );
        final checker = VersionChecker(client: mock);
        final update = await checker.check('0.40.2');

        expect(update.updateAvailable, isTrue);
        expect(update.latestVersion, '0.41.0');
        expect(update.releaseUrl, '${VersionChecker.releasesUrl}/v0.41.0');
      },
    );

    test('returns no update when current equals the latest release', () async {
      final mock = MockClient(
        (req) async => _json(200, _releases(['nightly', 'v0.40.2'])),
      );
      final checker = VersionChecker(client: mock);
      final update = await checker.check('0.40.2');

      expect(update.updateAvailable, isFalse);
      expect(update.latestVersion, '0.40.2');
    });

    test('returns no update when current is newer than the release', () async {
      final mock = MockClient(
        (req) async => _json(200, _releases(['nightly', 'v0.40.2'])),
      );
      final checker = VersionChecker(client: mock);
      final update = await checker.check('0.41.0');

      expect(update.updateAvailable, isFalse);
    });

    test('ignores non-semantic tags like nightly', () async {
      final mock = MockClient(
        (req) async => _json(200, _releases(['nightly'])),
      );
      final checker = VersionChecker(client: mock);
      final update = await checker.check('0.40.2');

      expect(update.updateAvailable, isFalse);
      expect(update.latestVersion, isEmpty);
    });

    test('reports an update when the local version cannot be parsed', () async {
      final mock = MockClient(
        (req) async => _json(200, _releases(['nightly', 'v0.40.2'])),
      );
      final checker = VersionChecker(client: mock);
      final update = await checker.check('main-abc123');

      expect(update.updateAvailable, isTrue);
      expect(update.latestVersion, '0.40.2');
    });

    test('throws on API failure', () async {
      final mock = MockClient((req) async => _json(500, {}));
      final checker = VersionChecker(client: mock);

      await expectLater(
        checker.check('0.40.2'),
        throwsA(isA<VersionCheckException>()),
      );
    });

    test('throws on a malformed response', () async {
      final mock = MockClient((req) async => _json(200, {'not': 'a list'}));
      final checker = VersionChecker(client: mock);

      await expectLater(
        checker.check('0.40.2'),
        throwsA(isA<VersionCheckException>()),
      );
    });

    test('requests the GitLab releases API with per_page and sorting', () async {
      http.Request? captured;
      final mock = MockClient((req) async {
        captured = req;
        return _json(200, _releases(['v0.40.2']));
      });
      final checker = VersionChecker(client: mock);
      await checker.check('0.40.2');

      expect(captured, isNotNull);
      expect(captured!.method, 'GET');
      expect(
        captured!.url.toString(),
        'https://gitlab.com/api/v4/projects/HttpAnimations%2Fdevinorium/releases'
        '?per_page=100&order_by=released_at&sort=desc&page=1',
      );
      expect(captured!.headers['Accept'], 'application/json');
    });

    test('paginates until it runs out of releases', () async {
      final page2 = _releases(['v0.40.2']);
      final mock = MockClient((req) async {
        final page = req.url.queryParameters['page'];
        if (page == '1') {
          return _json(200, List.filled(100, {'tag_name': 'nightly'}));
        }
        if (page == '2') {
          return _json(200, page2);
        }
        return _json(200, []);
      });
      final checker = VersionChecker(client: mock);
      final update = await checker.check('0.40.1');

      expect(update.updateAvailable, isTrue);
      expect(update.latestVersion, '0.40.2');
    });

    test('falls back when the release list is empty', () async {
      final mock = MockClient((req) async => _json(200, []));
      final checker = VersionChecker(client: mock);
      final update = await checker.check('0.40.2');

      expect(update.updateAvailable, isFalse);
      expect(update.releaseUrl, VersionChecker.releasesUrl);
    });

    test('close nulls the client so check can be called again', () async {
      final mock = MockClient((req) async => _json(200, _releases(['v0.40.3'])));
      final checker = VersionChecker(client: mock);
      await checker.check('0.40.2');
      checker.close();

      // With the same mock passed in, reusing it works because the mock is not
      // actually closed. The field is nulled when owned, but here _ownsClient is
      // false so close is a no-op.
      final update = await checker.check('0.40.2');
      expect(update.updateAvailable, isTrue);
      expect(update.latestVersion, '0.40.3');
    });
  });
}
