// lib/data_orchestrator.dart
import 'dart:async';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:intl/intl.dart';
import 'package:nissan_leaf_app/mqtt_settings.dart';
import 'package:nissan_leaf_app/obd/obd_connector.dart';
import 'package:simple_logger/simple_logger.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'async_safety.dart';
import 'background_service_controller.dart';
import 'data/reading_model.dart';
import 'data/readings_db.dart';
import 'mqtt_client.dart';
import 'mock_battery_states.dart';

/// Abstract interface for data orchestration
abstract class DataOrchestrator {
  Stream<Map<String, dynamic>> get statusStream;
  Future<bool> collectData();
  void dispose();

  /// Why the most recent [collectData] call returned false, or null if it
  /// succeeded (or hasn't run yet). Surfaced into the background service's
  /// heartbeat log so e.g. a BLE scan that came back empty because of a
  /// platform scan-throttle error is distinguishable from "genuinely nothing
  /// in range" - from the outside they used to look identical. See issue #3.
  String? get lastFailureReason;

  /// Whether the OBD dongle is connected right now. A live fact for
  /// DirectOBDOrchestrator (it holds the connection). For
  /// BackgroundServiceOrchestrator, which can't synchronously ask a
  /// different isolate, this is a best-effort value cached from the last
  /// status/refresh round trip - call [refreshStatus] to update it without
  /// triggering a real collection. Distinct from "is the service running"
  /// (#20): the service can be alive for long stretches between a failed
  /// cycle's disconnect and the next reconnect attempt (#17).
  bool get isConnected;

  /// Best-effort refresh of [isConnected] without running a real collection
  /// cycle. A no-op for orchestrators where [isConnected] is already live.
  Future<void> refreshStatus();
}

/// Orchestrator that connects directly to OBD (Debug Mode)
class DirectOBDOrchestrator implements DataOrchestrator {
  final _statusController = StreamController<Map<String, dynamic>>.broadcast();
  final OBDConnector _obdConnector;
  final ReadingsDatabase _db;
  final MqttClient _mqttClient;
  final _log = SimpleLogger();
  var _initialized = false;

  Future<void> _initialize() async {
    if (_initialized) return;
    await _obdConnector.initialize();

    final mqttSettings = MqttSettings();
    await mqttSettings.loadSettings();
    if (mqttSettings.enabled && mqttSettings.isValid()) {
      await _mqttClient.initialize(mqttSettings);
      _log.info('MQTT client initialized');
    }

    _initialized = true;
  }

  DirectOBDOrchestrator({
    OBDConnector? obdConnector,
    ReadingsDatabase? db,
    MqttClient? mqttClient,
  })  : _obdConnector = obdConnector ?? OBDConnector(),
        _db = db ?? ReadingsDatabase(),
        _mqttClient = mqttClient ?? MqttClient.instance {
    _log.info('Created DirectOBDOrchestrator');
  }

  @override
  Stream<Map<String, dynamic>> get statusStream => _statusController.stream;

  @override
  String? get lastFailureReason => _obdConnector.lastError;

  @override
  bool get isConnected => _obdConnector.isConnected;

  @override
  Future<void> refreshStatus() async {} // isConnected is already live

  final SingleFlight<bool> _collectGuard = SingleFlight<bool>();
  @override
  Future<bool> collectData() {
    return _collectGuard.run(() => _collectData());
  }

  Future<bool> _collectData() async {
    try {
      _initialize();
      _statusController.add({'collecting': true});
      _log.info('Starting direct OBD data collection');

      // Collect data
      _statusController.add({'status': 'Collecting data...'});
      final data = await _obdConnector.collectCarData();

      if (data == null) {
        _log.warning('No data collected from OBD');
        _statusController.add({'collecting': false, 'error': 'No data collected'});
        return false;
      }

      // Create reading and store/publish
      final reading = Reading.fromObdMap(data);
      await _db.insertReading(reading);
      _log.info('Saved reading to database');

      // Generate a unique session ID
      final sessionId = await _getOrCreateSessionId();

      try {
        // Publish to MQTT if connected
        if (_mqttClient.isConnected) {
          _log.info('Publishing to MQTT');
          await _mqttClient.publishBatteryData(
            stateOfCharge: reading.stateOfCharge,
            batteryHealth: reading.batteryHealth,
            batteryVoltage: reading.batteryVoltage,
            batteryCapacity: reading.batteryCapacity,
            estimatedRange: reading.estimatedRange,
            sessionId: sessionId,
            speed: reading.speed,
            odometer: reading.odometer,
            ambientTemp: reading.ambientTemp,
            l1l2Charges: reading.l1l2Charges,
            quickCharges: reading.quickCharges,
          );
        }
      } catch (e) {
        // swallow any exceptions, it's not critical
        _log.warning('MQTT publish failed: $e');
      }

      _statusController.add({
        'collecting': false,
        'stateOfCharge': reading.stateOfCharge,
        'batteryHealth': reading.batteryHealth,
        'estimatedRange': reading.estimatedRange,
        'timestamp': reading.timestamp.millisecondsSinceEpoch,
        'sessionId': sessionId
      });

      _log.info(
          'Successfully collected and stored battery data. SOC: ${reading.stateOfCharge}%, Health: ${reading.batteryHealth}%');
      return true;
    } catch (e, stackTrace) {
      _log.severe('Error in direct OBD data collection: $e\n$stackTrace');
      _statusController.add({'collecting': false, 'error': e.toString()});
      return false;
    }
  }

  /// Gets or creates a session ID
  Future<String> _getOrCreateSessionId() async {
    final prefs = await SharedPreferences.getInstance();
    String sessionId = prefs.getString('current_session_id') ?? '';
    final lastCollectionStr = prefs.getString('last_collection_time');

    bool createNewSession = sessionId.isEmpty || lastCollectionStr == null;

    if (!createNewSession) {
      try {
        final lastCollection = DateTime.parse(lastCollectionStr);
        if (DateTime.now().difference(lastCollection).inMinutes > 30) {
          createNewSession = true;
        }
      } catch (e) {
        // If we can't parse the last collection time, create a new session
        createNewSession = true;
      }
    }

    if (createNewSession) {
      sessionId = DateFormat('yyyy.MM.dd.HH.mm').format(DateTime.now().toUtc());
      prefs.setString('current_session_id', sessionId);
      _log.info('Starting new session: $sessionId');
    }

    // Update last collection time
    prefs.setString('last_collection_time', DateTime.now().toIso8601String());
    return sessionId;
  }

  @override
  void dispose() {
    // Best-effort - a cycle now stays connected on success (#17), so an
    // intentional stop while connected should hand the link back cleanly.
    // Fire-and-forget: dispose() is sync (called from Flutter State.dispose()
    // elsewhere, which can't await), and if the process is dying anyway the
    // OS reclaims the BLE GATT connection regardless.
    unawaited(_obdConnector.disconnect());
    _statusController.close();
  }
}

/// UI-side orchestrator that never touches Bluetooth directly - it asks the
/// real background-task isolate to collect, and reads the result back from
/// the database. Restores the pre-2025-03-21 architecture (the old
/// `BackgroundServiceOrchestrator`, built on `flutter_background_service`'s
/// `invoke`/`on`), lost when the app migrated to `flutter_foreground_task`
/// and `DashboardPage` started constructing its own `BackgroundService`/
/// `BluetoothDeviceManager` instead. That meant two isolates could
/// independently drive the same physical BLE connection at once - see #20.
///
/// The task's reply only carries success/failure, not the reading itself;
/// the database is the actual data transport, since it's a real file both
/// isolates reach independently rather than a Dart object confined to one
/// isolate's heap (see the isolate-memory discussion on #20).
class BackgroundServiceOrchestrator implements DataOrchestrator {
  final _statusController = StreamController<Map<String, dynamic>>.broadcast();
  final ReadingsDatabase _db;
  final _log = SimpleLogger();
  String? _lastFailureReason;

  // Best-effort, cached from the last status/refresh reply - this isolate
  // can't synchronously ask another one whether the dongle is connected
  // (#20). Defaults to false: assume disconnected until told otherwise,
  // rather than defaulting to a possibly-stale "connected".
  bool _connected = false;

  // Injectable for testing - these are static plugin calls that can't be
  // mocked directly.
  final Future<bool> Function() _isServiceRunning;
  final Future<bool> Function() _startService;
  final void Function(Object data) _sendDataToTask;
  final void Function(DataCallback callback) _addTaskDataCallback;
  final void Function(DataCallback callback) _removeTaskDataCallback;

  BackgroundServiceOrchestrator({
    ReadingsDatabase? db,
    Future<bool> Function()? isServiceRunning,
    Future<bool> Function()? startService,
    void Function(Object data)? sendDataToTask,
    void Function(DataCallback callback)? addTaskDataCallback,
    void Function(DataCallback callback)? removeTaskDataCallback,
  })  : _db = db ?? ReadingsDatabase(),
        _isServiceRunning = isServiceRunning ?? (() => FlutterForegroundTask.isRunningService),
        _startService = startService ?? BackgroundServiceController.startService,
        _sendDataToTask = sendDataToTask ?? FlutterForegroundTask.sendDataToTask,
        _addTaskDataCallback = addTaskDataCallback ?? FlutterForegroundTask.addTaskDataCallback,
        _removeTaskDataCallback = removeTaskDataCallback ?? FlutterForegroundTask.removeTaskDataCallback {
    _log.info('Created BackgroundServiceOrchestrator');
  }

  @override
  Stream<Map<String, dynamic>> get statusStream => _statusController.stream;

  @override
  String? get lastFailureReason => _lastFailureReason;

  @override
  bool get isConnected => _connected;

  @override
  Future<void> refreshStatus() async {
    if (!await _isServiceRunning()) {
      _connected = false;
      return;
    }
    // Short timeout - this is meant to be a cheap, frequent check (app
    // resume, mode switch, ...), not something the UI should ever visibly
    // wait on the way it might tolerate waiting on a real collection.
    final reply = await _requestAndAwaitReply('getStatus', 'status', timeout: const Duration(seconds: 5));
    if (reply != null && reply.containsKey('connected')) {
      _connected = reply['connected'] == true;
    }
  }

  @override
  Future<bool> collectData() async {
    _statusController.add({'collecting': true});
    _lastFailureReason = null;

    // A stopped service (5 consecutive failures - see background_service.dart
    // - or simply never started this run) isn't a dead end: the user is
    // right here asking for a read, which is exactly the kind of explicit
    // signal that should override "probably parked, stop polling." See #20
    // follow-up. Deliberately no extra care taken to avoid re-arming the
    // normal polling loop if this fails too - that's a separate, undecided
    // design question, not solved here.
    final serviceRunning = await _isServiceRunning();
    final refreshed = serviceRunning ? await _requestRefresh() : await _startAndAwaitInitialResult();
    if (!refreshed) {
      _statusController.add({'collecting': false, 'error': _lastFailureReason ?? 'Refresh failed'});
      return false;
    }

    final reading = await _db.getMostRecentReading();
    if (reading == null) {
      _lastFailureReason = 'No reading available after refresh';
      _statusController.add({'collecting': false, 'error': _lastFailureReason});
      return false;
    }

    _statusController.add({
      'collecting': false,
      'stateOfCharge': reading.stateOfCharge,
      'batteryHealth': reading.batteryHealth,
      'estimatedRange': reading.estimatedRange,
      'timestamp': reading.timestamp.millisecondsSinceEpoch,
    });
    return true;
  }

  /// Sends `refreshNow` and awaits the matching `refreshResult` reply.
  Future<bool> _requestRefresh() async {
    final reply = await _requestAndAwaitReply('refreshNow', 'refreshResult');
    if (reply == null) {
      _lastFailureReason = 'Timed out waiting for the background service';
      return false;
    }
    if (reply.containsKey('connected')) _connected = reply['connected'] == true;
    final success = reply['success'] == true;
    if (!success) _lastFailureReason = reply['reason']?.toString() ?? 'Refresh failed';
    return success;
  }

  /// Starts the background service and awaits the `startupResult` message its
  /// own `onStart()` sends once its initial collection cycle finishes.
  ///
  /// Deliberately does not also send `refreshNow`: `onStart()` already runs
  /// exactly one `TriggerType.manual` cycle on its own before anything else,
  /// so a second request here would either arrive before the freshly spawned
  /// isolate has registered its listener (lost), or land while that first
  /// cycle is still running (`busy`), or - worst case - run a second,
  /// redundant BLE round trip once it's free. `startupResult` is its own
  /// message type, sent only from this one place, so a pending wait here
  /// can't be satisfied by an unrelated timer cycle finishing around the
  /// same moment.
  Future<bool> _startAndAwaitInitialResult() async {
    final completer = Completer<Map<String, dynamic>?>();
    late DataCallback onData;
    final timer = Timer(const Duration(seconds: 30), () {
      _removeTaskDataCallback(onData);
      if (!completer.isCompleted) completer.complete(null);
    });

    onData = (Object data) {
      if (data is! Map || data['type'] != 'startupResult') return;
      timer.cancel();
      _removeTaskDataCallback(onData);
      if (!completer.isCompleted) completer.complete(Map<String, dynamic>.from(data));
    };
    _addTaskDataCallback(onData);

    if (!await _startService()) {
      timer.cancel();
      _removeTaskDataCallback(onData);
      _lastFailureReason = 'Failed to start the background service';
      return false;
    }

    final reply = await completer.future;
    if (reply == null) {
      _lastFailureReason = 'Timed out waiting for the background service to start';
      return false;
    }
    if (reply.containsKey('connected')) _connected = reply['connected'] == true;
    final success = reply['success'] == true;
    if (!success) _lastFailureReason = reply['reason']?.toString() ?? 'Startup collection failed';
    return success;
  }

  /// Sends [command] to the task and awaits a reply whose `type` matches
  /// [replyType], or null on timeout. Timeout-guarded rather than awaiting
  /// forever - a hung real service (see the zombie-isolate discussion on
  /// #3) should mean this gives up, not that the UI hangs too.
  Future<Map<String, dynamic>?> _requestAndAwaitReply(
    String command,
    String replyType, {
    Duration timeout = const Duration(seconds: 20),
  }) {
    final completer = Completer<Map<String, dynamic>?>();
    late DataCallback onData;
    final timer = Timer(timeout, () {
      _removeTaskDataCallback(onData);
      if (!completer.isCompleted) completer.complete(null);
    });

    onData = (Object data) {
      if (data is! Map || data['type'] != replyType) return;
      timer.cancel();
      _removeTaskDataCallback(onData);
      if (!completer.isCompleted) completer.complete(Map<String, dynamic>.from(data));
    };
    _addTaskDataCallback(onData);
    _sendDataToTask({'command': command});

    return completer.future;
  }

  @override
  void dispose() {
    _statusController.close();
  }
}

/// Orchestrator that generates mock data (Mock Mode & Web)
class MockDataOrchestrator implements DataOrchestrator {
  final _statusController = StreamController<Map<String, dynamic>>.broadcast();
  final _log = SimpleLogger();

  MockDataOrchestrator() {
    _log.info('Created MockDataOrchestrator');
  }

  @override
  Stream<Map<String, dynamic>> get statusStream => _statusController.stream;

  @override
  String? get lastFailureReason => null; // mock data collection never fails

  @override
  bool get isConnected => true; // mock mode has no real dongle to be connected to

  @override
  Future<void> refreshStatus() async {}

  @override
  Future<bool> collectData() async {
    _statusController.add({'collecting': true});
    _log.info('Generating mock battery data');

    // Generate mock reading
    final reading = MockBatteryStates.generateReading();

    _statusController.add({
      'collecting': false,
      'stateOfCharge': reading.stateOfCharge,
      'batteryHealth': reading.batteryHealth,
      'estimatedRange': reading.estimatedRange,
      'timestamp': DateTime.now().microsecondsSinceEpoch,
    });

    return true;
  }

  @override
  void dispose() {
    _statusController.close();
  }
}
