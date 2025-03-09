// lib/data_orchestrator.dart
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:nissan_leaf_app/async_safety.dart';
import 'package:simple_logger/simple_logger.dart';
import 'data/reading_model.dart';
import 'data/readings_db.dart';
import 'obd/bluetooth_device_manager.dart';
import 'obd/obd_command.dart';
import 'mqtt_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Orchestrates the data collection, storage, and publishing workflow
///
/// This class is responsible for coordinating:
/// - Data collection from the vehicle
/// - Storage of readings in the database
/// - Managing sessions
/// - Publishing to MQTT
class DataOrchestrator {
  // Singleton pattern
  static final DataOrchestrator _instance = DataOrchestrator._internal();
  static DataOrchestrator get instance => _instance;

  // Dependencies - initialized with default implementations
  BluetoothDeviceManager _deviceManager = BluetoothDeviceManager.instance;
  MqttClient _mqttClient = MqttClient.instance;
  ReadingsDatabase Function() _databaseFactory = () => ReadingsDatabase();

  // Getters for dependencies
  BluetoothDeviceManager get deviceManager => _deviceManager;
  MqttClient get mqttClient => _mqttClient;

  // Testing setters for dependencies
  @visibleForTesting
  void setDependencies({
    BluetoothDeviceManager? deviceManager,
    MqttClient? mqttClient,
    ReadingsDatabase Function()? databaseFactory,
  }) {
    if (deviceManager != null) _deviceManager = deviceManager;
    if (mqttClient != null) _mqttClient = mqttClient;
    if (databaseFactory != null) _databaseFactory = databaseFactory;
  }

  // Reset to default dependencies (useful for cleaning up after tests)
  @visibleForTesting
  void resetDependencies() {
    _deviceManager = BluetoothDeviceManager.instance;
    _mqttClient = MqttClient.instance;
    _databaseFactory = () => ReadingsDatabase();
  }

  final _log = SimpleLogger();
  final _statusController = StreamController<Map<String, dynamic>>.broadcast();

  /// Stream of collection status updates
  Stream<Map<String, dynamic>> get statusStream => _statusController.stream;

  // Private constructor
  DataOrchestrator._internal();

  /// Collects data from the vehicle, stores it, and publishes to MQTT
  ///
  /// Returns true if collection was successful
  final SingleFlight<bool> _collectDataGuard = SingleFlight<bool>();

  Future<bool> collectData({bool useMockMode = false}) async {
    return _collectDataGuard.run(() => _collectData(useMockMode: useMockMode));
  }

  Future<bool> _collectData({bool useMockMode = false}) async {
    // Set up device manager
    if (useMockMode) {
      _deviceManager.enableMockMode();
    }

    try {
      // Notify about collection start
      _updateStatus({'collecting': true, 'lastCollection': DateTime.now().toIso8601String()});

      // Collect battery data
      final batteryData = await _deviceManager.runCommand(OBDCommand.lbc);
      final rangeData = await _deviceManager.runCommand(OBDCommand.rangeRemaining);

      if (batteryData.isEmpty) {
        _log.warning('Failed to retrieve battery data');
        _updateStatus({'error': 'Failed to retrieve battery data', 'collecting': false});
        return false;
      }

      // Create a reading object from the collected data
      final reading = Reading.fromObdMap({
        ...batteryData,
        ...rangeData,
        'timeStamp': DateTime.now(),
      });

      // Save to database
      final db = _databaseFactory();
      await db.insertReading(reading);

      // Generate a unique session ID
      final sessionId = await _getOrCreateSessionId();

      // Publish to MQTT if connected
      if (_mqttClient.isConnected) {
        try {
          await _mqttClient.publishBatteryData(
            stateOfCharge: reading.stateOfCharge,
            batteryHealth: reading.batteryHealth,
            batteryVoltage: reading.batteryVoltage,
            batteryCapacity: reading.batteryCapacity,
            estimatedRange: reading.estimatedRange,
            sessionId: sessionId,
          );
          _log.info('Published data to MQTT');
        } catch (e) {
          _log.warning('Error publishing to MQTT: $e');
          // Continue even if MQTT fails
        }
      }

      // Notify about collection success
      _updateStatus({
        'collecting': false,
        'lastCollection': DateTime.now().toIso8601String(),
        'stateOfCharge': reading.stateOfCharge,
        'batteryHealth': reading.batteryHealth,
        'estimatedRange': reading.estimatedRange,
        'sessionId': sessionId
      });

      _log.info(
          'Successfully collected and stored battery data. SOC: ${reading.stateOfCharge}%, Health: ${reading.batteryHealth}%');
      return true;
    } catch (e, stackTrace) {
      _log.severe('Error in data collection: $e\n$stackTrace');
      _updateStatus({'error': e.toString(), 'collecting': false});
      return false;
    } finally {
      // Disconnect to save battery if we're not using mock mode
      if (_deviceManager.isConnected && !useMockMode) {
        await _deviceManager.disconnect();
      }
    }
  }

  /// Gets or creates a session ID
  ///
  /// A new session is started if:
  /// - No current session exists
  /// - It has been more than 30 minutes since the last collection
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
      sessionId = DateTime.now().millisecondsSinceEpoch.toString();
      prefs.setString('current_session_id', sessionId);
      _log.info('Starting new session: $sessionId');
    }

    // Update last collection time
    prefs.setString('last_collection_time', DateTime.now().toIso8601String());
    return sessionId;
  }

  /// Update status and notify listeners
  void _updateStatus(Map<String, dynamic> status) {
    if (!_statusController.isClosed) {
      _statusController.add(status);
    }
  }

  /// Clean up resources
  void dispose() {
    _statusController.close();
  }
}
