import 'package:flutter_test/flutter_test.dart';
import 'mock_timer.dart'; // Adjust import path as needed
import 'dart:async';

void main() {
  late MockTimerController timerController;

  setUp(() {
    timerController = MockTimerController();
  });

  tearDown(() {
    timerController.resetAll();
  });

  group('MockTimer basic functionality', () {
    test('one-shot timer creation and properties', () {
      final mockTimer = timerController.createTimer(const Duration(seconds: 5), () {});

      expect(mockTimer.isActive, true);
      expect(mockTimer.tick, 0);
      expect(mockTimer.isPeriodic, false);
      expect(mockTimer.duration, const Duration(seconds: 5));
    });

    test('periodic timer creation and properties', () {
      final mockTimer = timerController.createPeriodicTimer(const Duration(seconds: 10), (_) {});

      expect(mockTimer.isActive, true);
      expect(mockTimer.tick, 0);
      expect(mockTimer.isPeriodic, true);
      expect(mockTimer.duration, const Duration(seconds: 10));
    });

    test('timer cancellation', () {
      final mockTimer = timerController.createTimer(const Duration(seconds: 5), () {});

      expect(mockTimer.isActive, true);
      mockTimer.cancel();
      expect(mockTimer.isActive, false);
    });
  });

  group('One-shot timer firing', () {
    test('one-shot timer fires once', () {
      int callCount = 0;
      timerController.createTimer(const Duration(seconds: 5), () => callCount++);

      timerController.advanceBy(const Duration(seconds: 6));
      expect(callCount, 1);
    });

    test('one-shot timer deactivates after firing', () {
      late MockTimer mockTimer;
      mockTimer = timerController.createTimer(const Duration(seconds: 5), () {});

      timerController.advanceBy(const Duration(seconds: 6));
      expect(mockTimer.isActive, false);
    });

    test('one-shot timer does not fire before its time', () {
      int callCount = 0;
      timerController.createTimer(const Duration(seconds: 5), () => callCount++);

      timerController.advanceBy(const Duration(seconds: 4));
      expect(callCount, 0);
    });

    test('canceled one-shot timer does not fire', () {
      int callCount = 0;
      final mockTimer = timerController.createTimer(const Duration(seconds: 5), () => callCount++);

      mockTimer.cancel();
      timerController.advanceBy(const Duration(seconds: 10));
      expect(callCount, 0);
    });
  });

  group('Periodic timer firing', () {
    test('periodic timer fires multiple times', () {
      int callCount = 0;
      timerController.createPeriodicTimer(const Duration(seconds: 5), (_) => callCount++);

      timerController
          .advanceBy(const Duration(seconds: 16)); // Should fire 3 times (at 5s, 10s, 15s)
      expect(callCount, 3);
    });

    test('periodic timer stays active after firing', () {
      late MockTimer mockTimer;
      mockTimer = timerController.createPeriodicTimer(const Duration(seconds: 5), (_) {});

      timerController.advanceBy(const Duration(seconds: 10)); // Fire twice
      expect(mockTimer.isActive, true);
    });

    test('periodic timer tick property increments', () {
      late MockTimer mockTimer;
      mockTimer = timerController.createPeriodicTimer(const Duration(seconds: 5), (_) {});

      timerController.advanceBy(const Duration(seconds: 16)); // Should fire 3 times
      expect(mockTimer.tick, 3);
    });

    test('canceled periodic timer does not fire', () {
      int callCount = 0;
      final mockTimer =
          timerController.createPeriodicTimer(const Duration(seconds: 5), (_) => callCount++);

      mockTimer.cancel();
      timerController.advanceBy(const Duration(seconds: 20));
      expect(callCount, 0);
    });

    test('periodic timer callback receives the timer', () {
      Timer? receivedTimer;
      late MockTimer mockTimer;

      mockTimer = timerController.createPeriodicTimer(
          const Duration(seconds: 5), (timer) => receivedTimer = timer);

      timerController.advanceBy(const Duration(seconds: 5));
      expect(receivedTimer, mockTimer);
    });
  });

  group('Time advancement and firing order', () {
    test('timers fire in chronological order', () {
      final events = <String>[];

      timerController.createTimer(const Duration(seconds: 15), () => events.add('15s timer'));

      timerController.createTimer(const Duration(seconds: 5), () => events.add('5s timer'));

      timerController.createTimer(const Duration(seconds: 10), () => events.add('10s timer'));

      timerController.advanceBy(const Duration(seconds: 20));

      expect(events, ['5s timer', '10s timer', '15s timer']);
    });

    test('timers with same duration fire in creation order', () {
      final events = <String>[];

      timerController.createTimer(const Duration(seconds: 10), () => events.add('timer 1'));

      timerController.createTimer(const Duration(seconds: 10), () => events.add('timer 2'));

      timerController.createTimer(const Duration(seconds: 10), () => events.add('timer 3'));

      timerController.advanceBy(const Duration(seconds: 10));

      expect(events, ['timer 1', 'timer 2', 'timer 3']);
    });

    test('mixed periodic and one-shot timers fire in correct order', () {
      final events = <String>[];

      timerController.createPeriodicTimer(
          const Duration(seconds: 3), // Prime
          (_) => events.add('3s periodic'));

      timerController.createTimer(
          const Duration(seconds: 7), // Prime
          () => events.add('7s one-shot'));

      timerController.createPeriodicTimer(
          const Duration(seconds: 11), // Prime
          (_) => events.add('11s periodic'));

      timerController.advanceBy(const Duration(seconds: 17)); // Prime

      // With prime numbers, there should be no ambiguity in the order
      expect(events, [
        '3s periodic', // at 3s
        '3s periodic', // at 6s
        '7s one-shot', // at 7s
        '3s periodic', // at 9s
        '11s periodic', // at 11s
        '3s periodic', // at 12s
        '3s periodic', // at 15s
      ]);
    });

    test('advancement with no timers does not error', () {
      // Just verify this doesn't throw
      timerController.advanceBy(const Duration(seconds: 10));
    });

    test('partial advancement not reaching any timer duration', () {
      int callCount = 0;
      timerController.createTimer(const Duration(seconds: 5), () => callCount++);

      timerController.advanceBy(const Duration(seconds: 3));
      expect(callCount, 0);

      timerController.advanceBy(const Duration(seconds: 1));
      expect(callCount, 0);

      timerController.advanceBy(const Duration(seconds: 1));
      expect(callCount, 1);
    });
  });

  group('Complex timer scenarios', () {
    test('one-shot timer adds new timer when fired', () {
      final events = <String>[];

      timerController.createTimer(const Duration(seconds: 5), () {
        events.add('first timer');
        timerController.createTimer(const Duration(seconds: 5), () => events.add('nested timer'));
      });

      timerController.advanceBy(const Duration(seconds: 5));
      expect(events, ['first timer']);

      timerController.advanceBy(const Duration(seconds: 5));
      expect(events, ['first timer', 'nested timer']);
    });

    test('one-shot timer cancels another timer when fired', () {
      int secondTimerCalls = 0;
      late MockTimer timer2;

      timerController.createTimer(
          const Duration(seconds: 5), () => timer2.cancel() // First timer cancels second timer
          );

      timer2 = timerController.createTimer(const Duration(seconds: 10), () => secondTimerCalls++);

      timerController.advanceBy(const Duration(seconds: 15));
      expect(secondTimerCalls, 0); // Should not be called because it was canceled
    });

    test('multiple periodic timers with different durations', () {
      final events = <String>[];

      timerController.createPeriodicTimer(const Duration(seconds: 3), (_) => events.add('3s'));

      timerController.createPeriodicTimer(const Duration(seconds: 5), (_) => events.add('5s'));

      timerController.advanceBy(const Duration(seconds: 15));

      expect(events, [
        '3s', // at 3s
        '5s', // at 5s
        '3s', // at 6s
        '3s', // at 9s
        '5s', // at 10s
        '3s', // at 12s
        '3s', // at 15s
        '5s', // at 15s
      ]);
    });

    test('very long sequence of advancements', () {
      int calls3s = 0;
      int calls7s = 0;

      timerController.createPeriodicTimer(const Duration(seconds: 3), (_) => calls3s++);

      timerController.createPeriodicTimer(const Duration(seconds: 7), (_) => calls7s++);

      // Advance time in small increments
      for (int i = 0; i < 100; i++) {
        timerController.advanceBy(const Duration(seconds: 1));
      }

      // 3s timer should fire every 3 seconds: 3, 6, 9, 12, ... 99
      // Total fires = 100 / 3 = 33.33 = 33 fires
      expect(calls3s, 33);

      // 7s timer should fire every 7 seconds: 7, 14, 21, ... 98
      // Total fires = 100 / 7 = 14.28 = 14 fires
      expect(calls7s, 14);
    });
  });
}
