// lib/data_orchestrator.dart
import 'dart:async';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:intl/intl.dart';
import 'package:simple_logger/simple_logger.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'async_safety.dart';
import 'data/reading_model.dart';
import 'data/readings_db.dart';
import 'obd/bluetooth_device_manager.dart';
import 'mqtt_client.dart';
import 'mock_battery_states.dart';

/// Abstract interface for data orchestration
abstract class DataOrchestrator {
  Stream<Map<String, dynamic>> get statusStream;
  Future<bool> collectData();
  void dispose();
}

/// Orchestrator that uses background service (Real Mode)
class BackgroundServiceOrchestrator implements DataOrchestrator {
  final _statusController = StreamController<Map<String, dynamic>>.broadcast();
  StreamSubscription? _serviceSubscription;
  final _log = SimpleLogger();
  final FlutterBackgroundService _flutterBackgroundService;

  BackgroundServiceOrchestrator({FlutterBackgroundService? flutterBackgroundService})
      : _flutterBackgroundService = flutterBackgroundService ?? FlutterBackgroundService() {
    _serviceSubscription = _flutterBackgroundService.on('status').listen((status) {
      if (status != null) {
        _statusController.add(status);
      }
    });
    _log.info('Created BackgroundServiceOrchestrator');
  }

  @override
  Stream<Map<String, dynamic>> get statusStream => _statusController.stream;

  @override
  Future<bool> collectData() async {
    _log.info('Requesting data collection from background service');

    // Request collection from background service
    _flutterBackgroundService.invoke('manualCollect');

    // Wait for completion
    final completer = Completer<bool>();
    StreamSubscription? subscription;

    subscription = statusStream.listen((status) {
      if (status['collecting'] == false) {
        final success = !status.containsKey('error');
        completer.complete(success);
        subscription?.cancel();
      }
    });

    return completer.future.timeout(Duration(seconds: 30), onTimeout: () {
      _log.warning('Timeout waiting for background service response');
      subscription?.cancel();
      return false;
    });
  }

  @override
  void dispose() {
    _serviceSubscription?.cancel();
    _statusController.close();
  }
}

/// Orchestrator that connects directly to OBD (Debug Mode)
class DirectOBDOrchestrator implements DataOrchestrator {
  // TODO: move MQTT initialization here
  final _statusController = StreamController<Map<String, dynamic>>.broadcast();
  final BluetoothDeviceManager _deviceManager;
  final ReadingsDatabase _db;
  final MqttClient _mqttClient;
  final _log = SimpleLogger();
  var _initialized = false;

  Future<void> _initialize() async {
    if (_initialized) return;
    await _deviceManager.initialize();
    _initialized = true;
  }

  DirectOBDOrchestrator({
    BluetoothDeviceManager? deviceManager,
    ReadingsDatabase? db,
    MqttClient? mqttClient,
  })  : _deviceManager = deviceManager ?? BluetoothDeviceManager.instance,
        _db = db ?? ReadingsDatabase(),
        _mqttClient = mqttClient ?? MqttClient.instance {
    _log.info('Created DirectOBDOrchestrator for debug mode');
  }

  @override
  Stream<Map<String, dynamic>> get statusStream => _statusController.stream;

  @override
  Future<bool> collectData() async {
    try {
      _initialize();
      _statusController.add({'collecting': true});
      _log.info('Starting direct OBD data collection');

      // Connect if needed
      if (!_deviceManager.isConnected) {
        _statusController.add({'status': 'Connecting to OBD device...'});
        _log.info('Connecting to OBD device...');
        bool connected = await _deviceManager.autoConnectToObd();
        if (!connected) {
          _log.warning('Failed to connect to OBD device');
          _statusController.add({'collecting': false, 'error': 'Failed to connect to OBD device'});
          return false;
        }
      }

      // Collect data
      _statusController.add({'status': 'Collecting data...'});
      _log.info('Connected, collecting car data');
      final data = await _deviceManager.collectCarData();

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
      'lastCollection': DateTime.now().toIso8601String(),
    });

    return true;
  }

  @override
  void dispose() {
    _statusController.close();
  }
}

/// Singleton for backward compatibility
/// This provides compatibility for existing code that uses DataOrchestrator.instance
class DataOrchestratorLegacy implements DataOrchestrator {
  // Singleton pattern
  static final DataOrchestratorLegacy _instance = DataOrchestratorLegacy._internal();
  static DataOrchestratorLegacy get instance => _instance;

  // Current orchestrator
  late DataOrchestrator _delegate;
  final SingleFlight<bool> _collectDataGuard = SingleFlight<bool>();
  final _log = SimpleLogger();

  // Private constructor
  DataOrchestratorLegacy._internal() {
    _delegate = DirectOBDOrchestrator();
    _log.info('Created DataOrchestratorLegacy singleton');
  }

  // Set the active orchestrator implementation
  void setOrchestrator(DataOrchestrator orchestrator) {
    if (_delegate != orchestrator) {
      _log.info('Switching orchestrator implementation');
      _delegate.dispose();
      _delegate = orchestrator;
    }
  }

  // Implementation via delegation
  @override
  Stream<Map<String, dynamic>> get statusStream => _delegate.statusStream;

  @override
  Future<bool> collectData({bool useMockMode = false}) {
    return _collectDataGuard.run(() => _delegate.collectData());
  }

  @override
  void dispose() {
    _delegate.dispose();
  }
}
