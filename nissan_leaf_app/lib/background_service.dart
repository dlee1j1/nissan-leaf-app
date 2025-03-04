import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_background_service_android/flutter_background_service_android.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:simple_logger/simple_logger.dart';

import 'data/reading_model.dart';
import 'data/readings_db.dart';
import 'obd/obd_command.dart';
import 'obd/obd_controller.dart';
import 'obd/mock_obd_controller.dart';

// Key constants for shared preferences
const String _serviceEnabledKey = 'background_service_enabled';
const String _collectionFrequencyKey = 'collection_frequency_minutes';
const int _defaultFrequency = 15; // 15 minutes default

class BackgroundService {
  static final _log = SimpleLogger();
  static final FlutterBackgroundService _service = FlutterBackgroundService();
  static bool _isInitialized = false;
  static ObdController? _obdController;

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

    _isInitialized = true;
    _log.info('Background service initialized');
  }

  /// Request necessary permissions for the background service
  static Future<void> _requestPermissions() async {
    if (_isWebPlatform) return; // No permissions needed for web

    await Permission.notification.request();

    // These permissions are already handled in the BLE scan page,
    // but we request them again to be sure
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

  /// Set the OBD controller for testing
  static void setObdController(ObdController controller) {
    _obdController = controller;
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
    // Use the mock controller from _obdController if it's set
    ObdController? mockController = _obdController;

    // If no controller set, create a default one
    if (mockController == null) {
      _log.warning('No mock controller available for web simulation - using default');
      mockController = MockObdController('''
        7BB10356101FFFFF060
        7BB210289FFFFE763FF
        7BB22FFCA4A09584650
        7BB239608383E038700
        7BB24017000239A000C
        7BB25814C00191FB580
        7BB260005FFFFE763FF
        7BB27FFE56501AEFFFF''');
      (mockController as MockObdController).mockRangeResponse = '7BB 03 62 0E 24 05 DC';
    }

    // Set the controller for OBD commands
    OBDCommand.setObdController(mockController);

    try {
      // Notify about collection start
      _webStatusController
          .add({'collecting': true, 'lastCollection': DateTime.now().toIso8601String()});

      // Collect battery data
      final batteryData = await OBDCommand.lbc.run();
      final rangeData = await OBDCommand.rangeRemaining.run();

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

  // Initialize with a reasonable default frequency
  int collectionFrequencyMinutes = _defaultFrequency;
  bool isMockMode = false;
  ObdController? obdController = BackgroundService._obdController;
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

      if (obdController == null && !isMockMode) {
        // In a real implementation, we would:
        // 1. Scan for OBD device
        // 2. Connect to it
        // 3. Initialize OBD controller
        // For now, we'll just use mock data in non-testing scenarios
        final mockResponse = '''
        7BB10356101FFFFF060
        7BB210289FFFFE763FF
        7BB22FFCA4A09584650
        7BB239608383E038700
        7BB24017000239A000C
        7BB25814C00191FB580
        7BB260005FFFFE763FF
        7BB27FFE56501AEFFFF''';

        obdController = MockObdController(mockResponse);
        // Set range response too
        (obdController as MockObdController).mockRangeResponse = '7BB 03 62 0E 24 05 DC';
      }

      // Set the controller for OBD commands
      OBDCommand.setObdController(obdController!);

      // Collect battery data
      final batteryData = await OBDCommand.lbc.run();
      final rangeData = await OBDCommand.rangeRemaining.run();

      if (batteryData.isEmpty) {
        log.warning('Failed to retrieve battery data');
        // Update status with error
        service.invoke('status', {'error': 'Failed to retrieve battery data'});
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

      // Update status with successful collection
      service.invoke('status', {
        'collecting': false,
        'lastCollection': lastCollectionTime!.toIso8601String(),
        'stateOfCharge': stateOfCharge,
        'batteryHealth': batteryHealth,
        'estimatedRange': estimatedRange,
        'sessionId': sessionId
      });

      log.info(
          'Successfully collected and stored battery data. SOC: $stateOfCharge%, Health: $batteryHealth%');
    } catch (e, stackTrace) {
      log.severe('Error collecting data: $e\n$stackTrace');
      service.invoke('status', {'error': e.toString(), 'collecting': false});
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

      if (isMockMode && event['mockData'] != null) {
        // Set up mock controller with the provided data
        obdController = MockObdController(event['mockData']);
      } else {
        // Clear the mock controller when disabling mock mode
        obdController = null;
      }
    }
  });

  // Start the collection timer
  startCollectionTimer();

  // Keep service alive
  service.invoke('started', {});
}
