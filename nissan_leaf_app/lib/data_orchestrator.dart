// lib/data_orchestrator.dart
import 'dart:async';
import 'package:intl/intl.dart';
import 'package:nissan_leaf_app/mqtt_settings.dart';
import 'package:nissan_leaf_app/obd/obd_connector.dart';
import 'package:simple_logger/simple_logger.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'async_safety.dart';
import 'data/reading_model.dart';
import 'data/readings_db.dart';
import 'mqtt_client.dart';
import 'mock_battery_states.dart';

/// Abstract interface for data orchestration
abstract class DataOrchestrator {
  Stream<Map<String, dynamic>> get statusStream;
  Future<bool> collectData();
  void dispose();
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
