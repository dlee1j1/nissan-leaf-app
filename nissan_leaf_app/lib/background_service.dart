// lib/background_service.dart
import 'dart:async';
import 'dart:math';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:simple_logger/simple_logger.dart';
import 'mqtt_settings.dart';
import 'mqtt_client.dart';
import 'data_orchestrator.dart';

// Key constants for shared preferences
const String _serviceEnabledKey = 'background_service_enabled';
const String _collectionFrequencyKey = 'collection_frequency_minutes';
const int _defaultFrequency = 15; // 15 minutes default

class BackgroundService {
  static final _log = SimpleLogger();
  static final FlutterBackgroundService _service = FlutterBackgroundService();
  static bool _isInitialized = false;
  static final _orchestrator = DirectOBDOrchestrator();
  static get orchestrator => _orchestrator;

  /// Initialize the background service
  static Future<void> initialize() async {
    if (_isInitialized) return;

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

    _log.info('Starting background service');
    return await _service.startService();
  }

  /// Stop the background service
  static Future<void> stopService() async {
    // Save the service state
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_serviceEnabledKey, false);

    _log.info('Stopping background service');
    _service.invoke('stopService');
  }

  /// Check if the service is running
  static Future<bool> isServiceRunning() async {
    return await _service.isRunning();
  }

  /// Get the service stream for status updates
  static Stream<Map<String, dynamic>?> getStatusStream() {
    return _service.on('status');
  }

  /// Set the data collection frequency in minutes
  static Future<void> setCollectionFrequency(int minutes) async {
    if (minutes < 1) {
      throw ArgumentError('Collection frequency must be at least 1 minute');
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_collectionFrequencyKey, minutes);

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

  log.onLogged = (message, info) {
    service.invoke('log', {'message': message});
  };

  // Initialize with a reasonable default frequency
  int collectionFrequencyMinutes = _defaultFrequency;

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

  // Create orchestrator for data collection
  final orchestrator = BackgroundService.orchestrator;

  // Set up status forwarder
  orchestrator.statusStream.listen((status) {
    // Forward status updates to the service clients
    service.invoke('status', status);
  });

  // Start periodic collection
  Timer? timer;

  // Function to collect and store data using the orchestrator
  Future<bool> collectData() async {
    try {
      log.info('Collecting battery data');

      // Let the orchestrator handle the collection process
      return orchestrator.collectData();
    } catch (e, stackTrace) {
      log.severe('Error collecting data: $e\n$stackTrace');
      service.invoke('status', {'error': e.toString(), 'collecting': false});
      return false;
    }
  }

  const Duration maxDelay = Duration(minutes: 5);
  Duration computeNextDuration(Duration current, Duration base, bool success) {
    Duration ceiling = maxDelay > base ? maxDelay : base; // max
    Duration next;
    if (success) {
      next = base;
    } else {
      next = (current * 2 < ceiling) ? current * 2 : ceiling; // min
    }
    return next;
  }

  bool keepGoing;
  Future<void> collectDataAndKeepGoing() async {
    Duration base = Duration(minutes: collectionFrequencyMinutes);
    Duration current = base;
    keepGoing = true;
    while (keepGoing) {
      bool success = await collectData();
      var next = computeNextDuration(current, base, success);
      await Future.delayed(next);
    }
  }

  // Function to start the collection timer
  void startCollectionTimer() {
    // Also collect immediately when starting
    collectDataAndKeepGoing();
  }

  // Handle service lifecycle events
  service.on('stopService').listen((event) {
    log.info('Stopping background service');
//    timer?.cancel();
    keepGoing = false;
    orchestrator.dispose();
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

  service.on('manualCollect').listen((event) async {
    await collectData();
  });

  // Start the collection timer
  startCollectionTimer();

  // Keep service alive
  service.invoke('started', {});
}
