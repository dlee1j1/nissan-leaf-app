// File: test/utils/single_flight_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:nissan_leaf_app/async_safety.dart';
import 'dart:async';
import 'utils/fake_async_utils.dart';

void main() {
  group('SingleFlight Tests', () {
    test('returns same future for concurrent calls', () async {
      // Create a SingleFlight instance
      final SingleFlight<int> singleFlight = SingleFlight<int>();

      // Create a completer that we can control
      final completer = Completer<int>();

      // Call run twice with the same completer
      final future1 = singleFlight.run(() => completer.future);
      final future2 = singleFlight.run(() => completer.future);

      // Both futures should be identical
      expect(identical(future1, future2), true);

      // Complete the operation
      completer.complete(42);

      // Both futures should have the same result
      expect(await future1, 42);
      expect(await future2, 42);
    });

    test('allows new operations after completion', () async {
      // Create a SingleFlight instance
      final SingleFlight<int> singleFlight = SingleFlight<int>();

      // First operation
      final result1 = await singleFlight.run(() => Future.value(1));
      expect(result1, 1);

      // Second operation should be allowed to run
      final result2 = await singleFlight.run(() => Future.value(2));
      expect(result2, 2);
    });

    test('with FakeAsync - handles timing correctly for longer operations', () {
      runWithFakeAsync((fake) async {
        // Create a SingleFlight instance
        final SingleFlight<int> singleFlight = SingleFlight<int>();

        // Counter for number of actual operations
        int operationCounter = 0;

        // Create an operation that takes some time
        Future<int> operation() async {
          operationCounter++;
          // In a real test, this would be a network call or other slow operation
          await Future.delayed(Duration(seconds: 5));
          return 42;
        }

        // Start multiple operations concurrently
        final futures = <Future<int>>[];
        for (int i = 0; i < 5; i++) {
          futures.add(singleFlight.run(operation));
        }

        // Advance time to complete the operation
        fake.elapse(Duration(seconds: 6));

        // All futures should complete with the same result
        for (final future in futures) {
          expect(await future, 42);
        }

        // Even though we called run 5 times, the operation should only run once
        expect(operationCounter, 1);

        // After completion, a new operation should run
        final future = singleFlight.run(operation);
        fake.elapse(Duration(seconds: 6));
        expect(await future, 42);
        expect(operationCounter, 2);
      });
    });
  });
}
