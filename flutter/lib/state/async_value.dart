/// Async value states inspired by t3code's `AsyncResult`.
///
/// Every async piece of state is empty, loading, ready, or failed.
/// This makes it impossible to forget which state the UI is in.
sealed class AsyncValue<T> {
  const AsyncValue();

  const factory AsyncValue.empty() = AsyncEmpty<T>;
  const factory AsyncValue.loading() = AsyncLoading<T>;
  const factory AsyncValue.ready(T value) = AsyncReady<T>;
  const factory AsyncValue.error(Object error) = AsyncError<T>;

  bool get isEmpty => this is AsyncEmpty<T>;
  bool get isLoading => this is AsyncLoading<T>;
  bool get isReady => this is AsyncReady<T>;
  bool get isError => this is AsyncError<T>;

  T? get valueOrNull {
    if (this is AsyncReady<T>) return (this as AsyncReady<T>).value;
    return null;
  }

  Object? get errorOrNull {
    if (this is AsyncError<T>) return (this as AsyncError<T>).error;
    return null;
  }

  AsyncValue<R> map<R>(R Function(T) f) {
    return switch (this) {
      AsyncReady<T>(:final value) => AsyncValue.ready(f(value)),
      AsyncEmpty<T>() => const AsyncValue.empty(),
      AsyncLoading<T>() => const AsyncValue.loading(),
      AsyncError<T>(:final error) => AsyncValue.error(error),
    };
  }
}

final class AsyncEmpty<T> extends AsyncValue<T> {
  const AsyncEmpty();
}

final class AsyncLoading<T> extends AsyncValue<T> {
  const AsyncLoading();
}

final class AsyncReady<T> extends AsyncValue<T> {
  final T value;
  const AsyncReady(this.value);
}

final class AsyncError<T> extends AsyncValue<T> {
  final Object error;
  const AsyncError(this.error);
}
