/// t3code-style command scheduler for a single thread.
///
/// t3code uses a `serial` concurrency mode for all thread commands so that
/// `send`, `resume`, `stop`, and `approval` do not race on the same thread.
/// This is a lightweight Dart equivalent: a per-key FIFO queue of async tasks.
class ThreadCommandScheduler {
  final Map<String, Future<dynamic>> _inFlight = {};

  /// Run [f] for [key] after every previously scheduled [key] task completes.
  /// Tasks with different keys run in parallel.
  Future<T> run<T>(String key, Future<T> Function() f) {
    final previous = _inFlight[key];
    final current = previous == null
        ? Future(f)
        : previous.then((_) => f(), onError: (_) => f());
    _inFlight[key] = current;
    current.whenComplete(() {
      if (_inFlight[key] == current) _inFlight.remove(key);
    });
    return current;
  }

  void dispose() {
    _inFlight.clear();
  }
}
