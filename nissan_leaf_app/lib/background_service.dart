// lib/background_service.dart
// This file contains the refactored background service with orchestration logic removed
import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:simple_logger/simple_logger.dart';
import 'mqtt_settings.dart';
import 'mqtt_client.dart';

// Import the DataOrchestrator
import 'data_orchestrator.dart';

// Key constants for shared preferences
const String _serviceEnabledKey = 'background_service_enabled';
const String _collectionFrequencyKey = 'collection_frequency_minutes';
const int _defaultFrequency = 15; // 15 minutes default

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

  // Simplified web simulation now using DataOrchestrator
  static void _simulateWebCollection() async {
    // Use the orchestrator for collection, with a stream listener to handle status updates
    final orchestrator = DataOrchestrator.instance;
    final subscription = orchestrator.statusStream.listen((status) {
      _webStatusController.add(status);
    });

    try {
      await orchestrator.collectData(useMockMode: true);
    } catch (e) {
      _log.severe('Error in web simulation: $e');
      _webStatusController.add({'error': e.toString(), 'collecting': false});
    } finally {
      // Cancel subscription to avoid memory leaks
      subscription.cancel();
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

  // Initialize with a reasonable default frequency
  int collectionFrequencyMinutes = _defaultFrequency;
  bool isMockMode = false;

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

  // Function to collect and store data using the orchestrator
  Future<void> collectData() async {
    try {
      log.info('Collecting battery data');

      // Update the initial status
      service.invoke(
          'status', {'collecting': true, 'lastCollection': DateTime.now().toIso8601String()});

      // Set up a listener for status updates from the orchestrator
      final orchestrator = DataOrchestrator.instance;
      final subscription = orchestrator.statusStream.listen((status) {
        // Forward status updates to the service
        service.invoke('status', status);
      });

      try {
        // Use the orchestrator to collect data
        await orchestrator.collectData(useMockMode: isMockMode);
      } finally {
        // Ensure subscription is cancelled
        subscription.cancel();
      }
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
    }
  });

  service.on('manualCollect').listen((event) async {
    await collectData();
  });

  // Start the collection timer
  startCollectionTimer();

  // Keep service alive
  service.invoke('started', {});
}
