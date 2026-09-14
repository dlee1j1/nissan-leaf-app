// background_service.dart - the foreground-task handler
import 'dart:async';
import 'dart:io';
import 'dart:isolate' show Isolate;
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
/// the OBD dongle). There is no disconnect-based stop. A successful cycle
/// keeps the dongle link open for the next one (see #17); a failed cycle
/// drops it, but the receiver never subscribed to `ACL_DISCONNECTED` (#13/#14
/// - a bare drop mid-drive was noise back when every cycle produced one).
/// Reacting to a single disconnect now would mean the same thing, just
/// undebounced - the service instead stops itself once
/// [maxConsecutiveFailures] cycles have failed back to back, which means the
/// dongle is unreachable and we are almost certainly parked. See issue #13.
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

  /// Tags every heartbeat line with which BackgroundService wrote it.
  /// BackgroundService is constructed independently in at least two places
  /// that can be alive simultaneously: the real flutter_foreground_task
  /// background isolate, and DashboardPage's own copy via
  /// DataOrchestratorFactory.create(AppMode.real) in the main UI isolate
  /// (see #9) - opening the dashboard arms a second, independent
  /// execute()/timer loop there. Both write identically-formatted lines to
  /// the same heartbeat file, so without a tag there is no way to tell
  /// after the fact whether a given success came from the real headless
  /// service or from the UI's parallel one - a question that turned out to
  /// matter (see #3).
  static int _instanceCounter = 0;
  final String _instanceTag = kIsWeb
      ? 'web'
      : '${Isolate.current.debugName?.isEmpty ?? true ? "?" : Isolate.current.debugName}'
          '/${Isolate.current.hashCode}#${_instanceCounter++}';

  /// How this instance replies to the UI isolate (see #20 - restoring the
  /// message-passing pattern the pre-flutter_foreground_task
  /// BackgroundServiceOrchestrator used, lost in the 2025-03-21 plugin
  /// migration). Only the real background-isolate instance ever has a UI
  /// listening on the other end - FlutterForegroundTask.sendDataToMain is a
  /// safe no-op if IsolateNameServer has no port registered under its name,
  /// so this never throws even when called from an instance nobody's
  /// listening to (e.g. a stray UI-isolate one, or in tests).
  void Function(Object data) _sendToMain = FlutterForegroundTask.sendDataToMain;
  @visibleForTesting
  void setSendToMainForTesting(void Function(Object data) fn) {
    _sendToMain = fn;
  }

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
  String? get lastFailureReason => _orchestrator.lastFailureReason;

  @override
  bool get isConnected => _orchestrator.isConnected;

  @override
  Future<void> refreshStatus() async {} // isConnected is already live here

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
        _sendToMain({
          ..._statusSnapshot(),
          'type': 'startupResult',
          'success': false,
          'reason': 'missing prerequisites: ${missing.join(', ')}',
        });
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
      } finally {
        // Restarting-from-stopped (see #20 follow-up: pull-to-refresh
        // starting a self-stopped service) needs to know when *this specific*
        // startup cycle finishes, not just any cycle - a coincidental timer
        // cycle finishing around the same moment must not satisfy that wait.
        // A distinct message type, sent only here, keeps it unambiguous
        // without adding a second request/reply round trip on top of the
        // startup that's already happening.
        _sendToMain({..._statusSnapshot(), 'type': 'startupResult', 'success': _lastCollectionSuccess});
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
  ///
  /// Chained onto a queue rather than writing directly: two `unawaited()`
  /// callers close together (see execute()'s cycle-start/cycle-complete
  /// pair) would otherwise race the same file - this method itself awaits
  /// `getApplicationDocumentsDirectory()` before ever touching the file, so
  /// two near-simultaneous calls can genuinely overlap, and the loser's
  /// write can be silently dropped rather than merely reordered. Found by
  /// the cycle-start line vanishing outright in a test where collectData()
  /// resolves fast enough for exactly that race to happen every time.
  Future<void> _heartbeatQueue = Future.value();
  Future<void> _appendHeartbeat(String note) {
    _heartbeatQueue = _heartbeatQueue.then((_) => _doAppendHeartbeat(note));
    return _heartbeatQueue;
  }

  Future<void> _doAppendHeartbeat(String note) async {
    if (kIsWeb) return;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/service_heartbeat.log');
      await file.writeAsString(
        '${DateTime.now().toIso8601String()} [$_instanceTag] $note\n',
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

      // Fire-and-forget, written before any await below - if collectData()
      // hangs forever (e.g. a BLE connect that never resolves or throws;
      // nothing in that chain is currently timeout-guarded), the *completion*
      // heartbeat a few lines down never gets a chance to write, and the log
      // goes silent - indistinguishable from the isolate never having started
      // at all. This line is what tells the two apart after the fact: seeing
      // it with no matching completion line means execute() began and got
      // stuck inside; seeing neither means the isolate itself likely never
      // ran. See issue #3 - a real drive lost ~53 minutes to exactly this
      // ambiguity with no way to resolve it after the fact.
      unawaited(_appendHeartbeat('cycle-start trigger=${trigger.name}'));

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
      var note = 'cycle trigger=${trigger.name} success=$_lastCollectionSuccess';
      if (!_lastCollectionSuccess && _orchestrator.lastFailureReason != null) {
        // Distinguishes e.g. "scan came back empty because of a platform
        // scan-throttle error" from "genuinely nothing in range" - see #3.
        note += ' reason=${_orchestrator.lastFailureReason}';
      }
      unawaited(_appendHeartbeat(note));

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

  /// Handles commands sent from the UI isolate via
  /// `FlutterForegroundTask.sendDataToTask` (see #20). This is the only
  /// place the UI should ever learn about or influence collection state -
  /// it should not be constructing its own BackgroundService/
  /// BluetoothDeviceManager and colliding with this one over the same
  /// physical BLE connection.
  @override
  void onReceiveData(Object data) {
    if (data is! Map) {
      _log.warning('Received malformed data from UI: $data');
      return;
    }
    switch (data['command']) {
      case 'getStatus':
        _sendToMain(_statusSnapshot());
        break;
      case 'refreshNow':
        _handleRefreshNow();
        break;
      default:
        _log.warning('Unknown command from UI: ${data['command']}');
    }
  }

  Map<String, dynamic> _statusSnapshot() => {
        'type': 'status',
        'running': !_stopRequested,
        'executing': _executing,
        'lastTrigger': _lastTrigger.name,
        'lastCollectionSuccess': _lastCollectionSuccess,
        'consecutiveFailures': _consecutiveFailures,
        // The actual dongle link, not just "is the service alive" - these
        // diverge for long stretches between a failed cycle's disconnect
        // and the next reconnect attempt (#17). See the isConnected doc on
        // DataOrchestrator for why this needs to travel in the message
        // rather than being asked for synchronously.
        'connected': _orchestrator.isConnected,
      };

  void _handleRefreshNow() {
    if (_executing) {
      _sendToMain({..._statusSnapshot(), 'type': 'refreshResult', 'success': false, 'reason': 'busy'});
      return;
    }
    if (_stopRequested) {
      _sendToMain({..._statusSnapshot(), 'type': 'refreshResult', 'success': false, 'reason': 'stopped'});
      return;
    }
    execute(TriggerType.manual).then((_) {
      _sendToMain({..._statusSnapshot(), 'type': 'refreshResult', 'success': _lastCollectionSuccess});
    });
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
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    _log.info('Background service being destroyed${isTimeout ? ' (timeout)' : ''}');
    // isTimeout is new in flutter_foreground_task 9.0+: true when the OS tore
    // the service down because it didn't stop in time (the
    // ForegroundServiceDidNotStopInTime family of exceptions the 9.2.2
    // changelog says it fixed - see issue #22). Worth keeping in the durable
    // log since a real occurrence would be direct evidence for or against
    // that fix actually holding.
    await _appendHeartbeat(isTimeout ? 'stop (timeout)' : 'stop');
    try {
      dispose();
    } catch (e, stackTrace) {
      _log.severe('Error during onDestroy: $e\n$stackTrace');
    }
  }
}
