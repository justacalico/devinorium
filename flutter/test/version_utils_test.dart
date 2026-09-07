import 'package:devinorium_frontend/utils/version_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Version.parse', () {
    test('parses plain semantic versions', () {
      final v = Version.parse('0.40.2');
      expect(v, isNotNull);
      expect(v!.core, [0, 40, 2]);
      expect(v.pre, isNull);
    });

    test('strips a leading v or V', () {
      expect(Version.parse('v0.40.2')?.core, [0, 40, 2]);
      expect(Version.parse('V1.0.0')?.core, [1, 0, 0]);
      expect(Version.parse('vv1.0.0')?.core, [1, 0, 0]);
    });

    test('rejects leading zeros and signs in numeric identifiers', () {
      expect(Version.parse('01.02.03'), isNull);
      expect(Version.parse('+1.0.0'), isNull);
      expect(Version.parse('1.0.0-1'), isNotNull);
      expect(Version.parse('1.0.0-+1'), isNull);
      expect(Version.parse('1.0.0-0a'), isNotNull);
    });

    test('constructor asserts core length', () {
      expect(() => Version(core: [1, 2]), throwsAssertionError);
    });

    test('uses unmodifiable lists', () {
      final v = Version.parse('1.0.0-alpha.1')!;
      expect(() => v.core.add(4), throwsUnsupportedError);
      expect(() => v.pre!.add('x'), throwsUnsupportedError);
    });

    test('ignores build metadata after +', () {
      final v = Version.parse('0.40.2+51');
      expect(v, isNotNull);
      expect(v!.core, [0, 40, 2]);
    });

    test('parses pre-release identifiers', () {
      final v = Version.parse('1.0.0-beta.1');
      expect(v, isNotNull);
      expect(v!.core, [1, 0, 0]);
      expect(v.pre, ['beta', '1']);
    });

    test('rejects empty pre-release identifiers', () {
      expect(Version.parse('1.0.0-'), isNull);
      expect(Version.parse('1.0.0-beta.'), isNull);
      expect(Version.parse('1.0.0-.beta'), isNull);
    });

    test('returns null for non-version tags', () {
      expect(Version.parse('nightly'), isNull);
      expect(Version.parse('latest'), isNull);
      expect(Version.parse(''), isNull);
      expect(Version.parse('0.40'), isNull);
    });

    test('toString omits build metadata but keeps pre-release', () {
      expect(Version.parse('v0.40.2+51')?.toString(), '0.40.2');
      expect(Version.parse('1.0.0-beta.1')?.toString(), '1.0.0-beta.1');
    });

    test('value equality works', () {
      expect(Version.parse('v0.40.2'), Version.parse('0.40.2'));
      expect(Version.parse('0.40.2+51'), Version.parse('0.40.2'));
      expect(Version.parse('0.40.2'), isNot(Version.parse('0.40.3')));
    });
  });

  group('Version.compareTo', () {
    test('orders by major, minor, patch', () {
      expect(_cmp('0.40.1', '0.40.2'), -1);
      expect(_cmp('0.40.2', '0.40.2'), 0);
      expect(_cmp('0.41.0', '0.40.2'), 1);
      expect(_cmp('1.0.0', '0.99.99'), 1);
    });

    test('treats a release as newer than its pre-release', () {
      expect(_cmp('1.0.0-beta.1', '1.0.0'), -1);
      expect(_cmp('1.0.0', '1.0.0-beta.1'), 1);
    });

    test('orders pre-release identifiers', () {
      expect(_cmp('1.0.0-alpha', '1.0.0-beta'), -1);
      expect(_cmp('1.0.0-beta.1', '1.0.0-beta.2'), -1);
    });

    test('compares very large numeric pre-release identifiers', () {
      expect(
        _cmp('1.0.0-${'9' * 30}', '1.0.0-${'1' * 31}'),
        -1,
      );
    });

    test(
      'numeric pre-release identifiers have lower precedence than non-numeric',
      () {
        expect(_cmp('1.0.0-1a', '1.0.0-2'), 1);
        expect(_cmp('1.0.0-2', '1.0.0-1a'), -1);
        expect(_cmp('1.0.0-a', '1.0.0-1'), 1);
      },
    );

    test('strips leading v and build metadata when comparing', () {
      expect(_cmp('v0.40.2', '0.40.2'), 0);
      expect(_cmp('0.40.2+51', '0.40.2'), 0);
      expect(_cmp('0.40.2', '0.40.3'), -1);
    });
  });
}

int _cmp(String a, String b) => Version.parse(a)!.compareTo(Version.parse(b)!);
