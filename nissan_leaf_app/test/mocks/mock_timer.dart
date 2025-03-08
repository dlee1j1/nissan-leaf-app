import 'dart:async';

class MockTimer implements Timer {
  final Duration duration;
  final Function? _callback;
  final Function(Timer)? _periodicCallback;
  final bool _isPeriodic;
  bool _isActive = true;
  int _tick = 0;

  // Constructor for one-shot timer
  MockTimer.oneShot(this.duration, Function callback)
      : _callback = callback,
        _periodicCallback = null,
        _isPeriodic = false;

  // Constructor for periodic timer
  MockTimer.periodic(this.duration, Function(Timer) callback)
      : _callback = null,
        _periodicCallback = callback,
        _isPeriodic = true;

  @override
  bool get isActive => _isActive;

  @override
  int get tick => _tick;

  @override
  void cancel() {
    _isActive = false;
  }

  bool get isPeriodic => _isPeriodic;

  void fire() {
    if (!_isActive) return;

    _tick++;

    if (_isPeriodic) {
      _periodicCallback!(this);
    } else {
      Function cb = _callback!;
      _isActive = false; // One-shot timers deactivate after firing
      cb();
    }
  }
}

// Track both the timer and its absolute scheduled time
class _TimerSchedule {
  final MockTimer timer;
  final int creationTimeMs;

  _TimerSchedule(this.timer, this.creationTimeMs);

  int get nextFireTimeMs {
    if (!timer.isActive) return -1;

    if (timer.isPeriodic) {
      // Calculate next firing based on ticks
      return creationTimeMs + (timer.tick + 1) * timer.duration.inMilliseconds;
    } else if (timer.tick == 0) {
      // One-shot timer that hasn't fired
      return creationTimeMs + timer.duration.inMilliseconds;
    } else {
      // One-shot timer that has already fired
      return -1;
    }
  }
}

class MockTimerController {
  final List<_TimerSchedule> _timerSchedules = [];
  int _currentTimeMs = 0;

  // Getter for active timer count
  int get activeTimerCount => _timerSchedules.where((s) => s.timer.isActive).length;

  MockTimer createTimer(Duration duration, Function() callback) {
    final timer = MockTimer.oneShot(duration, callback);
    _timerSchedules.add(_TimerSchedule(timer, _currentTimeMs));
    return timer;
  }

  MockTimer createPeriodicTimer(Duration duration, Function(Timer) callback) {
    final timer = MockTimer.periodic(duration, callback);
    _timerSchedules.add(_TimerSchedule(timer, _currentTimeMs));
    return timer;
  }

  void advanceBy(Duration duration) {
    final targetTimeMs = _currentTimeMs + duration.inMilliseconds;

    // Keep advancing time and firing timers until we reach target time
    while (_currentTimeMs < targetTimeMs) {
      // Find next timer to fire
      int nextFireTimeMs = targetTimeMs;
      List<_TimerSchedule> schedulesToFire = [];

      for (final schedule in _timerSchedules) {
        final fireTimeMs = schedule.nextFireTimeMs;
        if (fireTimeMs > 0 && fireTimeMs <= targetTimeMs) {
          if (fireTimeMs < nextFireTimeMs) {
            // This timer fires earlier than others we've found
            nextFireTimeMs = fireTimeMs;
            schedulesToFire = [schedule];
          } else if (fireTimeMs == nextFireTimeMs) {
            // This timer fires at the same time as others
            schedulesToFire.add(schedule);
          }
        }
      }

      if (schedulesToFire.isEmpty) {
        // No more timers to fire, jump to target time
        _currentTimeMs = targetTimeMs;
        break;
      }

      // Advance time to next firing
      _currentTimeMs = nextFireTimeMs;

      // Fire all timers scheduled for this time
      for (final schedule in schedulesToFire) {
        if (schedule.timer.isActive) {
          schedule.timer.fire();
        }
      }

      // Remove inactive timers
      _timerSchedules.removeWhere((s) => !s.timer.isActive);
    }
  }

  void resetAll() {
    _timerSchedules.clear();
    _currentTimeMs = 0;
  }
}
