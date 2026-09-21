import 'dart:async';

const _defaultTtl = Duration(seconds: 2);
const _slowThreshold = Duration(milliseconds: 100);

class _CacheEntry {
  final Object value;
  final DateTime expiresAt;

  _CacheEntry(this.value, this.expiresAt);

  bool get isExpired => DateTime.now().isAfter(expiresAt);
}

class _InFlightEntry {
  _InFlightEntry(this.future);

  final Future<Object?> future;

  // Flipped by invalidate/clear: the future still resolves for its callers
  // but its result must not be written into the cache.
  bool valid = true;
}

/// Coalesces in-flight requests, caches successful results, and reports loads
/// that take longer than 100ms so the UI can avoid waiting on network round
/// trips more than once.
class Preloader {
  Preloader({this.enabled = true, this.onSlowLoad});

  final bool enabled;
  final void Function(String key, Duration elapsed)? onSlowLoad;

  final _inFlight = <String, _InFlightEntry>{};
  final _cache = <String, _CacheEntry>{};

  /// Fetch [key], reusing an in-flight request or a cached value when
  /// available. [ttl] defaults to two seconds.
  Future<T> load<T>(
    String key,
    Future<T> Function() fetch, {
    Duration? ttl,
  }) async {
    if (!enabled) return fetch();

    final cached = _cache[key];
    if (cached != null && !cached.isExpired) {
      return cached.value as T;
    }

    final existing = _inFlight[key];
    if (existing != null) {
      return (await existing.future) as T;
    }

    final stopwatch = Stopwatch()..start();
    late final _InFlightEntry entry;
    final future = fetch().then((value) {
      _inFlight.remove(key);
      final effectiveTtl = ttl ?? _defaultTtl;
      if (entry.valid && effectiveTtl > Duration.zero) {
        _cache[key] = _CacheEntry(value as Object, DateTime.now().add(effectiveTtl));
      }
      _maybeReport(key, stopwatch.elapsed);
      return value;
    }).onError((error, stackTrace) {
      _inFlight.remove(key);
      throw error!;
    });

    entry = _InFlightEntry(future);
    _inFlight[key] = entry;
    return future;
  }

  /// Start [fetch] for [key] without awaiting the result. Errors are ignored.
  void preload<T>(String key, Future<T> Function() fetch, {Duration? ttl}) {
    if (!enabled) return;
    unawaited(load(key, fetch, ttl: ttl).then((_) {}, onError: (_) {}));
  }

  /// Remove any cached or in-flight entry whose key starts with [prefix].
  /// Called after a mutation so stale lists and detail pages are refetched.
  void invalidate(String prefix) {
    _cache.removeWhere((key, _) => key.startsWith(prefix));
    // In-flight futures are left running for their callers, but their
    // results carry pre-mutation data and must never reach the cache.
    for (final entry in _inFlight.entries) {
      if (entry.key.startsWith(prefix)) entry.value.valid = false;
    }
    _inFlight.removeWhere((key, _) => key.startsWith(prefix));
  }

  /// Clear every cached and in-flight entry.
  void clear() {
    _cache.clear();
    for (final entry in _inFlight.values) {
      entry.valid = false;
    }
    _inFlight.clear();
  }

  void _maybeReport(String key, Duration elapsed) {
    if (elapsed <= _slowThreshold) return;
    onSlowLoad?.call(key, elapsed);
  }
}
