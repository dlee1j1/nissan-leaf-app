// File: test/utils/fake_async_utils.dart
import 'dart:async';
import 'package:fake_async/fake_async.dart';

/// Runs the given callback using FakeAsync.
///
/// This function simplifies the use of FakeAsync in tests by handling the common
/// pattern of running a function with FakeAsync and then elapsing all pending timers.
///
/// Example:
/// ```dart
/// test('my test with fake time', () {
///   runWithFakeAsync((fake) async {
///     // Your test code here
///     // Use fake.elapse(Duration(...)) to advance time
///
///     // All pending microtasks and timers will be automatically processed
///   });
/// });
/// ```
FutureOr<T> runWithFakeAsync<T>(FutureOr<T> Function(FakeAsync fake) callback) {
  return FakeAsync().run((fake) {
    final result = callback(fake);

    if (result is Future) {
      bool complete = false;

      // Using unawaited future to setup completion tracking
      // Cast to non-null since we've already checked it's a Future
      unawaited((result as Future).then((_) {
        complete = true;
      }, onError: (_) {
        complete = true;
      }));

      // Process microtasks and advance time until the future completes
      // or we hit a reasonable limit (to avoid infinite loops)
      int iterations = 0;
      while (!complete && iterations < 1000) {
        fake.flushMicrotasks();
        if (!complete) {
          fake.elapse(const Duration(milliseconds: 10));
        }
        iterations++;
      }

      if (iterations >= 1000 && !complete) {
        throw Exception('Future did not complete after 1000 iterations in FakeAsync');
      }
    }

    // Final flush to ensure all microtasks are processed
    fake.flushMicrotasks();

    return result;
  });
}

/// Mark a future as intentionally not awaited.
/// This is used to avoid the "unawaited futures" lint warning.
void unawaited(Future<dynamic> future) {}
