import 'dart:async';

import 'package:devinorium_frontend/utils/preloader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Preloader', () {
    test('calls fetch and returns value', () async {
      final preloader = Preloader();
      int calls = 0;
      final value = await preloader.load<int>('key', () async {
        calls++;
        return 42;
      });
      expect(value, 42);
      expect(calls, 1);
    });

    test('caches value for the given TTL', () async {
      final preloader = Preloader();
      int calls = 0;
      Future<int> fetch() async {
        calls++;
        return calls;
      }

      expect(await preloader.load<int>('key', fetch, ttl: Duration(seconds: 1)), 1);
      expect(await preloader.load<int>('key', fetch, ttl: Duration(seconds: 1)), 1);
      expect(calls, 1);
    });

    test('expires cache after TTL', () async {
      final preloader = Preloader();
      int calls = 0;
      Future<int> fetch() async {
        calls++;
        return calls;
      }

      await preloader.load<int>('key', fetch, ttl: Duration(milliseconds: 1));
      await Future.delayed(Duration(milliseconds: 20));
      final value = await preloader.load<int>('key', fetch, ttl: Duration(milliseconds: 1));
      expect(value, 2);
      expect(calls, 2);
    });

    test('coalesces in-flight requests', () async {
      final preloader = Preloader();
      int calls = 0;
      final completer = Completer<int>();

      Future<int> fetch() async {
        calls++;
        return completer.future;
      }

      final f1 = preloader.load<int>('key', fetch);
      final f2 = preloader.load<int>('key', fetch);
      expect(calls, 1);

      completer.complete(7);
      expect(await f1, 7);
      expect(await f2, 7);
      expect(calls, 1);
    });

    test('rethrows errors without caching them', () async {
      final preloader = Preloader();
      int calls = 0;
      Future<int> fetch() async {
        calls++;
        throw Exception('nope');
      }

      await expectLater(
        () => preloader.load<int>('key', fetch),
        throwsException,
      );
      await expectLater(
        () => preloader.load<int>('key', fetch),
        throwsException,
      );
      expect(calls, 2);
    });

    test('invalidates cache entries by prefix', () async {
      final preloader = Preloader();
      await preloader.load<int>('a:one', () async => 1);
      await preloader.load<int>('a:two', () async => 2);
      await preloader.load<int>('b:one', () async => 3);

      preloader.invalidate('a:');

      int calls = 0;
      await preloader.load<int>('a:one', () async {
        calls++;
        return 10;
      });
      await preloader.load<int>('a:two', () async {
        calls++;
        return 20;
      });
      await preloader.load<int>('b:one', () async {
        calls++;
        return 30;
      });

      expect(calls, 2);
    });

    test('does nothing when disabled', () async {
      final preloader = Preloader(enabled: false);
      int calls = 0;
      Future<int> fetch() async {
        calls++;
        return calls;
      }

      expect(await preloader.load<int>('key', fetch), 1);
      expect(await preloader.load<int>('key', fetch), 2);
      expect(calls, 2);
    });

    test('reports slow loads', () async {
      final logs = <String>[];
      final preloader = Preloader(
        onSlowLoad: (key, elapsed) => logs.add(key),
      );
      await preloader.load<int>('slow', () async {
        await Future.delayed(Duration(milliseconds: 200));
        return 1;
      });
      expect(logs, ['slow']);
    });
  });
}
