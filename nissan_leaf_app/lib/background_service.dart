// background_service.dart - the foreground-task handler
import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:meta/meta.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:simple_logger/simple_logger.dart';
import 'data_orchestrator.dart';

/// Default poll interval, in minutes.
const int defaultFrequency = 1;

enum TriggerType {
  timer,
  manual;
}

/// Handler that implements the background service logic.
///
/// Lifecycle is driven from the native side: `ObdConnectionReceiver` starts the
/// service when a recognised Bluetooth device connects (the Leaf head unit or
/// the OBD dongle). There is no disconnect-based stop — the collection flow
/// drops the dongle link every cycle by design. Instead the service stops
/// itself once [maxConsecutiveFailures] cycles have failed back to back, which
/// means the dongle is unreachable and we are almost certainly parked. See
/// issue #13.
class BackgroundService extends TaskHandler implements DataOrchestrator {
  static BackgroundService? _instance;

  final SimpleLogger _log = SimpleLogger();
  DataOrchestrator _orchestrator;
  final bool _createdOrchestrator;

  /// Stop the service once this many collection cycles fail in a row. At the
  /// default 1-minute interval that is a ~5-minute shutdown after parking.
  static const int maxConsecutiveFailures = 5;

  Duration _baseInterval = const Duration(minutes: defaultFrequency);
  TriggerType _lastTrigger = TriggerType.timer;
  bool _lastCollectionSuccess = true;
  int _consecutiveFailures = 0;
  bool _stopRequested = false;
  Timer? _timer;
  bool _executing = false;

  /// Factory constructor that returns the singleton instance.
  factory BackgroundService({DataOrchestrator? orchestrator}) {
    _instance ??= BackgroundService._internal(orchestrator: orchestrator);
    return _instance!;
  }

  @visibleForTesting
  void setOrchestratorForTesting(DataOrchestrator orchestrator) {
    _orchestrator = orchestrator;
  }

  /// Drop the singleton so the next [BackgroundService] call builds a fresh one.
  /// Tests share this process, and a stale instance carries a pending timer and
  /// an `_executing` flag into the next test.
  @visibleForTesting
  static void resetForTesting() {
    _instance?._timer?.cancel();
    _instance = null;
  }

  BackgroundService._internal({DataOrchestrator? orchestrator})
      : _orchestrator = orchestrator ?? (kIsWeb ? MockDataOrchestrator() : DirectOBDOrchestrator()),
        _createdOrchestrator = (orchestrator != null);

  @override
  Stream<Map<String, dynamic>> get statusStream => _orchestrator.statusStream;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    try {
      _log.info('Background service started - starter: ${starter.name}');
      await _appendHeartbeat('start (${starter.name})');

      _executing = false;
      _consecutiveFailures = 0;
      _stopRequested = false;

      // Permissions can be revoked between drives, and the service is started
      // headless by the native receiver - so re-check here rather than trusting
      // a check that ran at app launch. See issue #3.
      final missing = await _missingPrerequisites();
      if (missing.isNotEmpty) {
        _log.severe('Missing prerequisites, stopping service: ${missing.join(', ')}');
        await _appendHeartbeat('abort - missing prerequisites: ${missing.join(', ')}');
        try {
          await FlutterForegroundTask.stopService();
        } catch (e) {
          _log.warning('Error stopping service after failed prerequisite check: $e');
        }
        return;
      }

      try {
        await execute(TriggerType.manual);
      } catch (e) {
        _log.severe('Error during initial collection: $e');
      }
    } catch (e, stackTrace) {
      _log.severe('Fatal error in onStart: $e\n$stackTrace');
    }
  }

  /// Required runtime permissions. Returns the missing ones (empty when all
  /// granted).
  Future<List<String>> _missingPrerequisites() async {
    if (kIsWeb) return const [];
    final missing = <String>[];

    Future<void> check(String label, Permission permission) async {
      try {
        if (!await permission.isGranted) missing.add(label);
      } catch (e) {
        _log.warning('Error checking $label permission: $e');
      }
    }

    await check('notifications', Permission.notification);
    await check('bluetoothConnect', Permission.bluetoothConnect);
    await check('bluetoothScan', Permission.bluetoothScan);
    return missing;
  }

  /// Append a timestamped line to the heartbeat log so a completed drive can be
  /// confirmed after the fact (the only verification available without a rig).
  Future<void> _appendHeartbeat(String note) async {
    if (kIsWeb) return;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/service_heartbeat.log');
      await file.writeAsString(
        '${DateTime.now().toIso8601String()} $note\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (e) {
      _log.warning('Failed to append heartbeat: $e');
    }
  }

  @override
  Future<bool> collectData() async {
    await execute(TriggerType.manual);
    return _lastCollectionSuccess;
  }

  /// Schedule the next collection one [_baseInterval] out.
  Future<void> _scheduleNextCollection() async {
    _timer?.cancel();
    _timer = Timer(_baseInterval, () => execute(TriggerType.timer));

    try {
      FlutterForegroundTask.updateService(
        notificationTitle: 'Nissan Leaf Battery Tracker',
        notificationText: 'Collecting every ${_baseInterval.inMinutes} min '
            '(${_success[_lastTrigger]}/${_tries[_lastTrigger]} ok)',
      );
    } catch (e) {
      _log.warning('Failed to update notification: $e');
    }
  }

  // stats
  final Map<TriggerType, int> _success = {TriggerType.manual: 0, TriggerType.timer: 0};
  final Map<TriggerType, int> _tries = {TriggerType.manual: 0, TriggerType.timer: 0};

  void computeStats(TriggerType trigger) {
    _tries[trigger] = (_tries[trigger] ?? 0) + 1;
    _success[trigger] = (_success[trigger] ?? 0) + (_lastCollectionSuccess ? 1 : 0);
    _log.info('Stats:$trigger - ${_success[trigger]}/${_tries[trigger]}');
  }

  /// Main collection execution method.
  Future<void> execute(TriggerType trigger) async {
    if (_executing || _stopRequested) return;

    _executing = true;
    try {
      _log.info('Executing based on $trigger');
      _lastTrigger = trigger;
      _timer?.cancel();

      try {
        FlutterForegroundTask.updateService(
          notificationTitle: 'Nissan Leaf Battery Tracker',
          notificationText: 'Collecting battery data...',
        );
      } catch (e) {
        _log.warning('Failed to update notification: $e');
      }

      try {
        _lastCollectionSuccess = await _orchestrator.collectData().onError((e, stackTrace) {
          _log.severe('Error collecting data: $e\n$stackTrace');
          return false;
        });
      } catch (e, stackTrace) {
        _log.severe('Unexpected error in execute: $e\n$stackTrace');
        _lastCollectionSuccess = false;
      }

      computeStats(trigger);
      // Fire-and-forget: the heartbeat is a diagnostic side-channel and must not
      // extend the _executing critical section or shift collection timing.
      unawaited(_appendHeartbeat('cycle trigger=${trigger.name} success=$_lastCollectionSuccess'));

      if (_lastCollectionSuccess) {
        _consecutiveFailures = 0;
      } else if (++_consecutiveFailures >= maxConsecutiveFailures) {
        _log.info('$_consecutiveFailures collections failed in a row - stopping (probably parked)');
        _stopRequested = true;
        _timer?.cancel();
        await _appendHeartbeat('stop: $_consecutiveFailures failed cycles');
        try {
          await FlutterForegroundTask.stopService();
        } catch (e) {
          _log.warning('Error stopping service after repeated failures: $e');
        }
        return;
      }

      await _scheduleNextCollection();
    } catch (e, stackTrace) {
      _log.severe('Fatal error in background service execute: $e\n$stackTrace');
      _lastCollectionSuccess = false;
      if (!_stopRequested) {
        try {
          await _scheduleNextCollection();
        } catch (setupError) {
          _log.severe('Failed to set up next collection: $setupError');
        }
      }
    } finally {
      _executing = false;
    }
  }

  /// Update the poll interval (minutes). Takes effect on the next cycle.
  void updateCollectionFrequency(int minutes) {
    _baseInterval = Duration(minutes: minutes);
    _log.info('Updated collection frequency to $minutes minutes');
    execute(TriggerType.manual);
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    // Unused: eventAction is nothing(). Scheduling is driven by our own timer
    // (see _scheduleNextCollection); liveness is tracked in service_heartbeat.log.
  }

  @override
  void dispose() {
    try {
      _timer?.cancel();
      if (_createdOrchestrator) {
        try {
          _orchestrator.dispose();
        } catch (e) {
          _log.warning('Error disposing orchestrator: $e');
        }
      }
    } catch (e) {
      _log.severe('Error during dispose: $e');
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    _log.info('Background service being destroyed');
    await _appendHeartbeat('stop');
    try {
      dispose();
    } catch (e, stackTrace) {
      _log.severe('Error during onDestroy: $e\n$stackTrace');
    }
  }
}
