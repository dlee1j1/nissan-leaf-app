import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:simple_logger/simple_logger.dart';

import 'data/reading_model.dart';
import 'data/readings_db.dart';
import 'obd/obd_command.dart';
import 'obd/bluetooth_device_manager.dart';

import 'mqtt_client.dart';
import 'mqtt_settings.dart';

// Key constants for shared preferences
const String _serviceEnabledKey = 'background_service_enabled';
const String _collectionFrequencyKey = 'collection_frequency_minutes';
const int _defaultFrequency = 15; // 15 minutes default

//TODO: test background service using mocktail
class BackgroundService {
  static final _log = SimpleLogger();
  static final FlutterBackgroundService _service = FlutterBackgroundService();
  static bool _isInitialized = false;

  // Web simulation variables
  static bool _webSimulationRunning = false;
  static Timer? _webSimulationTimer;
  static final _webStatusController = StreamController<Map<String, dynamic>>.broadcast();

  // Check if running on web
  static bool get _isWebPlatform => kIsWeb;

  /// Initialize the background service
  static Future<void> initialize() async {
    if (_isInitialized) return;

    if (_isWebPlatform) {
      _log.info('Web platform detected - using simulated background service');
      _isInitialized = true;
      return;
    }

    // Request necessary permissions
    await _requestPermissions();

    // Initialize notifications
    final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
        FlutterLocalNotificationsPlugin();

    // Initialize notification channel for Android
    const AndroidNotificationChannel channel = AndroidNotificationChannel(
      'nissan_leaf_battery_tracker',
      'Nissan Leaf Battery Tracker Service',
      description: 'Collects battery data in the background',
      importance: Importance.low,
    );

    await flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);

    // Configure background service
    await _service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: _onStart,
        autoStart: false,
        isForegroundMode: true,
        notificationChannelId: 'nissan_leaf_battery_tracker',
        initialNotificationTitle: 'Nissan Leaf Battery Tracker',
        initialNotificationContent: 'Initializing...',
        foregroundServiceNotificationId: 888,
      ),
      iosConfiguration: IosConfiguration(
        autoStart: false,
        onForeground: _onStart,
        onBackground: _onIosBackground,
      ),
    );

    // Initialize MQTT client if settings are available
    final mqttSettings = MqttSettings();
    await mqttSettings.loadSettings();
    if (mqttSettings.enabled && mqttSettings.isValid()) {
      final mqttClient = MqttClient.instance;
      await mqttClient.initialize(mqttSettings);
      _log.info('MQTT client initialized');
    }

    _isInitialized = true;
    _log.info('Background service initialized');
  }

  /// Request necessary permissions for the background service
  static Future<void> _requestPermissions() async {
    if (_isWebPlatform) return; // No permissions needed for web

    await Permission.notification.request();

    // Bluetooth permissions
    await Permission.bluetooth.request();
    await Permission.bluetoothConnect.request();
    await Permission.bluetoothScan.request();
    await Permission.location.request();
  }

  /// Start the background service
  static Future<bool> startService() async {
    if (!_isInitialized) {
      await initialize();
    }

    // Save the service state
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_serviceEnabledKey, true);

    if (_isWebPlatform) {
      _startWebSimulation();
      return true;
    }

    return await _service.startService();
  }

  /// Stop the background service
  static Future<void> stopService() async {
    // Save the service state
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_serviceEnabledKey, false);

    if (_isWebPlatform) {
      _stopWebSimulation();
    }

    _log.info('Stopping background service');
    _service.invoke('stopService');
  }

  /// Check if the service is running
  static Future<bool> isServiceRunning() async {
    if (_isWebPlatform) {
      return _webSimulationRunning;
    }
    return await _service.isRunning();
  }

  /// Get the service stream for status updates
  static Stream<Map<String, dynamic>?> getStatusStream() {
    if (_isWebPlatform) {
      return _webStatusController.stream;
    }
    return _service.on('status');
  }

  // run the collection code
  static Future<bool> collectManually() async {
    // For web platform, use direct simulation
    if (_isWebPlatform) {
      try {
        _simulateWebCollection();
        return true;
      } catch (e) {
        _log.severe('Error in web collection: $e');
        return false;
      }
    }

    // For non-web, check if the service is running
    if (!await isServiceRunning()) {
      _log.warning('Background service not running - cannot collect data');
      return false;
    }

    // Create a completer to wait for the result
    final completer = Completer<bool>();

    // Set up a subscription to catch the result
    StreamSubscription? statusSubscription;
    statusSubscription = getStatusStream().listen((status) {
      if (status == null) return;

      // Check if this is a collection result
      if (status.containsKey('collecting') && status['collecting'] == false) {
        // Collection completed
        statusSubscription?.cancel();

        // Check if there was an error
        if (status.containsKey('error')) {
          completer.complete(false);
          return;
        }

        completer.complete(true);
      }
    });

    // Trigger the collection
    _service.invoke('manualCollect', {});

    // Wait for result with timeout
    try {
      return await completer.future.timeout(const Duration(seconds: 10));
    } catch (e) {
      statusSubscription.cancel();
      _log.warning('Timeout waiting for collection result');
      return false;
    }
  }

  /// Set the data collection frequency in minutes
  static Future<void> setCollectionFrequency(int minutes) async {
    if (minutes < 1) {
      throw ArgumentError('Collection frequency must be at least 1 minute');
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_collectionFrequencyKey, minutes);

    if (_isWebPlatform) {
      if (_webSimulationRunning) {
        _startWebSimulation(); // Restart with new frequency
      }
      return;
    }

    // Update the running service if it's active
    if (await isServiceRunning()) {
      _service.invoke('updateFrequency', {'minutes': minutes});
    }
  }

  /// Get the data collection frequency in minutes
  static Future<int> getCollectionFrequency() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_collectionFrequencyKey) ?? _defaultFrequency;
  }

  /// Check if the service is set to auto-start
  static Future<bool> isServiceEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_serviceEnabledKey) ?? false;
  }

  // Web simulation methods
  static void _startWebSimulation() async {
    _webSimulationTimer?.cancel();
    _webSimulationRunning = true;

    int minutes = await getCollectionFrequency();
    // Use a faster interval for web demo, but still show correct minutes in UI
    final collectionInterval = _isWebPlatform ? Duration(seconds: 15) : Duration(minutes: minutes);
    _log.info('Web simulation starting with interval: ${collectionInterval.inSeconds} seconds');

    _webSimulationTimer = Timer.periodic(collectionInterval, (_) {
      _simulateWebCollection();
    });

    // Run immediately
    _simulateWebCollection();
  }

  static void _stopWebSimulation() {
    _webSimulationTimer?.cancel();
    _webSimulationTimer = null;
    _webSimulationRunning = false;
    _log.info('Web simulation stopped');
  }

  static void _simulateWebCollection() async {
    // Enable mock mode in BluetoothDeviceManager
    final manager = BluetoothDeviceManager.instance;
    manager.enableMockMode();

    try {
      // Notify about collection start
      _webStatusController
          .add({'collecting': true, 'lastCollection': DateTime.now().toIso8601String()});

      // Collect battery data
      final batteryData = await manager.runCommand(OBDCommand.lbc);
      final rangeData = await manager.runCommand(OBDCommand.rangeRemaining);

      if (batteryData.isEmpty) {
        _log.warning('Failed to retrieve mock battery data');
        _webStatusController.add({'error': 'Failed to retrieve battery data', 'collecting': false});
        return;
      }

      // Create a reading object from the collected data
      final stateOfCharge = (batteryData['state_of_charge'] as num?)?.toDouble() ?? 0.0;
      final batteryHealth = (batteryData['hv_battery_health'] as num?)?.toDouble() ?? 0.0;
      final batteryVoltage = (batteryData['hv_battery_voltage'] as num?)?.toDouble() ?? 0.0;
      final batteryCapacity = (batteryData['hv_battery_Ah'] as num?)?.toDouble() ?? 0.0;
      final estimatedRange = (rangeData['range_remaining'] as num?)?.toDouble() ?? 0.0;

      final reading = Reading(
        timestamp: DateTime.now(),
        stateOfCharge: stateOfCharge,
        batteryHealth: batteryHealth,
        batteryVoltage: batteryVoltage,
        batteryCapacity: batteryCapacity,
        estimatedRange: estimatedRange,
      );

      // Save to database (this should work in web)
      final db = ReadingsDatabase();
      await db.insertReading(reading);

      // Generate a unique session ID
      final prefs = await SharedPreferences.getInstance();
      String sessionId =
          prefs.getString('current_session_id') ?? DateTime.now().millisecondsSinceEpoch.toString();
      prefs.setString('current_session_id', sessionId);

      // Notify about collection success
      _webStatusController.add({
        'collecting': false,
        'lastCollection': DateTime.now().toIso8601String(),
        'stateOfCharge': stateOfCharge,
        'batteryHealth': batteryHealth,
        'estimatedRange': estimatedRange,
        'sessionId': sessionId
      });

      _log.info(
          'Successfully simulated data collection in web mode. SOC: $stateOfCharge%, Health: $batteryHealth%');
    } catch (e, stackTrace) {
      _log.severe('Error in web simulation: $e\n$stackTrace');
      _webStatusController.add({'error': e.toString(), 'collecting': false});
    }
  }
}

/// iOS background handler - needed for iOS support
@pragma('vm:entry-point')
Future<bool> _onIosBackground(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  return true;
}

/// Main background service function - this runs when the service starts
@pragma('vm:entry-point')
void _onStart(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();

  final log = SimpleLogger();
  log.info('Background service started');

  // Create a database instance
  final db = ReadingsDatabase();

  // Initialize BluetoothDeviceManager
  final deviceManager = BluetoothDeviceManager.instance;
  await deviceManager.initialize();

  // Initialize with a reasonable default frequency
  int collectionFrequencyMinutes = _defaultFrequency;
  bool isMockMode = false;
  DateTime? lastCollectionTime;

  // Access shared preferences to get the collection frequency
  final prefs = await SharedPreferences.getInstance();
  collectionFrequencyMinutes = prefs.getInt(_collectionFrequencyKey) ?? _defaultFrequency;

  // Update service notification content
  if (service is AndroidServiceInstance) {
    service.setForegroundNotificationInfo(
      title: 'Nissan Leaf Battery Tracker',
      content: 'Running in background, collecting every $collectionFrequencyMinutes minutes',
    );
  }

  // Start periodic collection
  Timer? timer;

  // Function to collect and store data
  Future<void> collectData() async {
    try {
      log.info('Collecting battery data');
      // Update the status
      service.invoke(
          'status', {'collecting': true, 'lastCollection': DateTime.now().toIso8601String()});

      // Use centralized method
      final carData = await deviceManager.collectCarData();

      if (carData == null) {
        log.warning('Failed to retrieve battery data');
        // Update status with error
        service.invoke('status', {'error': 'Failed to retrieve battery data'});
        return;
      }

      final reading = Reading.fromObdMap(carData);

      // Generate a unique session ID if we're starting a new session
      // A new session is defined as being more than 30 minutes since the last collection
      String sessionId = prefs.getString('current_session_id') ?? '';
      if (sessionId.isEmpty ||
          lastCollectionTime == null ||
          DateTime.now().difference(lastCollectionTime!).inMinutes > 30) {
        sessionId = DateTime.now().millisecondsSinceEpoch.toString();
        prefs.setString('current_session_id', sessionId);
        log.info('Starting new session: $sessionId');
      }

      // Save the reading to the database
      await db.insertReading(reading);
      lastCollectionTime = DateTime.now();

// Publish to MQTT if enabled
      final mqttClient = MqttClient.instance;
      if (mqttClient.isConnected) {
        try {
          await mqttClient.publishBatteryData(
            stateOfCharge: reading.stateOfCharge,
            batteryHealth: reading.batteryHealth,
            batteryVoltage: reading.batteryVoltage,
            batteryCapacity: reading.batteryCapacity,
            estimatedRange: reading.estimatedRange,
            sessionId: sessionId,
          );
          log.info('Published data to MQTT');
        } catch (e) {
          log.warning('Error publishing to MQTT: $e');
        }
      }
      // Update status with successful collection
      service.invoke('status', {
        'collecting': false,
        'lastCollection': lastCollectionTime!.toIso8601String(),
        'stateOfCharge': reading.stateOfCharge,
        'batteryHealth': reading.batteryHealth,
        'estimatedRange': reading.estimatedRange,
        'sessionId': sessionId
      });

      log.info(
          'Successfully collected and stored battery data. SOC: ${reading.stateOfCharge}%, Health: ${reading.batteryHealth}%');
    } catch (e, stackTrace) {
      log.severe('Error collecting data: $e\n$stackTrace');
      service.invoke('status', {'error': e.toString(), 'collecting': false});
    } finally {
      // Disconnect to save battery if we're not using mock mode
      if (deviceManager.isConnected && !isMockMode) {
        await deviceManager.disconnect();
      }
    }
  }

  // Function to start the collection timer
  void startCollectionTimer() {
    timer = Timer.periodic(Duration(minutes: collectionFrequencyMinutes), (timer) async {
      await collectData();
    });

    // Also collect immediately when starting
    collectData();
  }

  // Handle service lifecycle events
  service.on('stopService').listen((event) {
    log.info('Stopping background service');
    timer?.cancel();

    // Disconnect if connected
    if (deviceManager.isConnected) {
      deviceManager.disconnect();
    }

    // Clean up MQTT resources
    final mqttClient = MqttClient.instance;
    mqttClient.dispose();

    service.stopSelf();
  });

  service.on('updateFrequency').listen((event) {
    if (event != null && event['minutes'] != null) {
      collectionFrequencyMinutes = event['minutes'];
      log.info('Updated collection frequency to $collectionFrequencyMinutes minutes');

      // Restart the timer with the new frequency
      timer?.cancel();
      startCollectionTimer();

      // Update notification
      if (service is AndroidServiceInstance) {
        service.setForegroundNotificationInfo(
          title: 'Nissan Leaf Battery Tracker',
          content: 'Running in background, collecting every $collectionFrequencyMinutes minutes',
        );
      }
    }
  });

  service.on('setMockMode').listen((event) {
    if (event != null && event['enabled'] != null) {
      isMockMode = event['enabled'];
      log.info('Mock mode set to: $isMockMode');

      if (isMockMode) {
        // Enable mock mode
        if (deviceManager.isConnected) {
          deviceManager.disconnect();
        }
        deviceManager.enableMockMode(
          mockResponse: event['mockData'],
          mockRangeResponse: event['mockRangeData'],
        );
      } else {
        // Disable mock mode
        deviceManager.disableMockMode();
      }
    }
  });

  // Start the collection timer
  startCollectionTimer();

  // Keep service alive
  service.invoke('started', {});
}
