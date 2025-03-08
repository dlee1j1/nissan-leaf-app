/// A utility class that prevents multiple concurrent executions of an asynchronous function.
///
/// This class ensures that if a function is already running, subsequent calls will await
/// the same Future instead of starting a new execution. Once the function completes,
/// the next call will trigger a fresh execution.
///
/// This is useful for avoiding redundant network requests, expensive computations,
/// or reentrant function calls in an async context.
///
/// Example usage:
///
/// ```dart
/// final SingleFlight<bool> _autoConnectGuard = SingleFlight<bool>();
///
/// Future<bool> autoConnectToObd() {
///   return _autoConnectGuard.run(() => _autoConnectToObd());
/// }
/// ```
///
/// In this example, if `autoConnectToObd()` is called multiple times while an instance
/// is already running, all callers will share the same Future rather than invoking
/// `_autoConnectToObd()` multiple times.
///
/// Once the Future completes, new calls will initiate a new execution.
class SingleFlight<T> {
  Future<T>? _inFlight;

  Future<T> run(Future<T> Function() computation) {
    if (_inFlight != null) {
      return _inFlight!;
    }
    _inFlight = computation().whenComplete(() {
      _inFlight = null; // Allow subsequent calls once the current one finishes.
    });
    return _inFlight!;
  }
}
