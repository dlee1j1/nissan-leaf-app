// lib/background_service.dart
import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:simple_logger/simple_logger.dart';
import 'package:workmanager/workmanager.dart';
import 'mqtt_settings.dart';
import 'mqtt_client.dart';
import 'data_orchestrator.dart';

// Key constants for shared preferences
const String _serviceEnabledKey = 'background_service_enabled';
const String _collectionFrequencyKey = 'collection_frequency_minutes';
const String _lastCollectionResultKey = 'last_collection_result';
const String _previousDurationMsKey = 'previous_duration_ms';
const int _defaultFrequency = 15; // 15 minutes default

class BackgroundService {
  static final _log = SimpleLogger();
  static FlutterBackgroundService _service = FlutterBackgroundService();
  static bool _isInitialized = false;
  static final _orchestrator = DirectOBDOrchestrator();
  static get orchestrator => _orchestrator;
  static bool _shouldRequestPermission = true;

  // Duration constant for maximum backoff
  // ignore: constant_identifier_names
  static const Duration MAX_BACKOFF_DURATION = Duration(minutes: 5);

  // Workmanager instance - injectable for testing
  static Workmanager _workmanager = Workmanager();

  // Unique task names
  static const String _taskName = "leafBatteryDataCollection";
  static const String _oneTimeTaskName = "leafBatteryOneTimeCollection";

  // Method to set a mock Workmanager for testing
  @visibleForTesting
  static void setWorkmanagerForTesting(Workmanager mockWorkmanager) {
    _workmanager = mockWorkmanager;
  }

  @visibleForTesting
  static void setBackgroundServiceForTesting(FlutterBackgroundService mockBackgroundService) {
    _service = mockBackgroundService;
  }

  @visibleForTesting
  static void setShouldRequestPermission(bool b) {
    _shouldRequestPermission = b;
  }

  /// Initialize the background service
  static Future<void> initialize() async {
    if (_isInitialized) return;

    // Initialize WorkManager
    await _workmanager.initialize(_callbackDispatcher);

    if (_shouldRequestPermission) {
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
    }
    // Restore previous state if the service was enabled
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_serviceEnabledKey) ?? false) {
      await startService();
    }

    _isInitialized = true;
    _log.info('Background service initialized');
  }

  /// Request necessary permissions for the background service
  static Future<void> _requestPermissions() async {
    if (!_shouldRequestPermission) return; // skip if we are testing
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

    // Reset success state when starting
    await prefs.setBool(_lastCollectionResultKey, true);

    _log.info('Starting background service');

    // Start the foreground service for UI interactions
    await _service.startService();

    // Schedule the first one-time task
    await _scheduleOneTimeTask();

    return true;
  }

  /// Stop the background service
  static Future<void> stopService() async {
    // Save the service state
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_serviceEnabledKey, false);

    _log.info('Stopping background service');

    // Stop the foreground service
    _service.invoke('stopService');

    // Cancel all WorkManager tasks
    await _workmanager.cancelAll();
  }

  /// Schedule the next data collection task
  static Future<void> _scheduleOneTimeTask() async {
    final prefs = await SharedPreferences.getInstance();
    final baseFrequencyMinutes = await getCollectionFrequency();
    final baseDuration = Duration(minutes: baseFrequencyMinutes);

    // Get previous duration from prefs (in milliseconds for precision)
    final previousDurationMs = prefs.getInt(_previousDurationMsKey);
    final previousDuration =
        previousDurationMs != null ? Duration(milliseconds: previousDurationMs) : baseDuration;

    // Get last result
    final lastCollectionSucceeded = prefs.getBool(_lastCollectionResultKey) ?? true;

    // Compute next interval
    final nextInterval =
        computeNextInterval(baseDuration, previousDuration, lastCollectionSucceeded);

    // Save this as the previous duration for next time
    await prefs.setInt(_previousDurationMsKey, nextInterval.inMilliseconds);

    _log.info(
        'Scheduling next collection in ${nextInterval.inMinutes} minutes, ${nextInterval.inSeconds % 60} seconds');

    // Schedule a one-time task
    await _workmanager.registerOneOffTask(
      _oneTimeTaskName,
      _taskName,
      initialDelay: nextInterval,
      constraints: Constraints(
        networkType: NetworkType.connected,
        requiresBatteryNotLow: true,
      ),
      existingWorkPolicy: ExistingWorkPolicy.replace,
    );
  }

  /// Compute next interval based on previous duration and success
  static Duration computeNextInterval(
      Duration baseDuration, Duration previousDuration, bool wasSuccessful) {
    // If base duration is already greater than max backoff, just use it
    if (baseDuration > MAX_BACKOFF_DURATION) {
      return baseDuration;
    }

    // For successful collections, reset to base duration
    if (wasSuccessful) {
      return baseDuration;
    }

    // For failures, double the previous duration with capping
    final newDuration = previousDuration * 2;
    return newDuration > MAX_BACKOFF_DURATION ? MAX_BACKOFF_DURATION : newDuration;
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

  /// Directly collect data for immediate UI feedback
  static Future<void> manualCollect() async {
    _log.info('Manual collection requested');

    // Send status update to UI
    _service.invoke('status', {'collecting': true});

    try {
      final success = await _orchestrator.collectData();

      // Update status
      _service.invoke('status', {
        'collecting': false,
        'success': success,
        'lastCollection': DateTime.now().toIso8601String(),
      });

      // Update last result
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_lastCollectionResultKey, success);

      _log.info('Manual collection completed successfully: $success');
    } catch (e) {
      _log.severe('Error in manual collection: $e');
      _service.invoke('status', {
        'collecting': false,
        'error': e.toString(),
      });

      // Update failure status
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_lastCollectionResultKey, false);
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

/// WorkManager callback dispatcher
@pragma('vm:entry-point')
void _callbackDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    // Initialize what's needed in the isolate
    WidgetsFlutterBinding.ensureInitialized();

    final prefs = await SharedPreferences.getInstance();
    final isEnabled = prefs.getBool(_serviceEnabledKey) ?? false;

    // If service has been disabled, don't reschedule
    if (!isEnabled) {
      return true;
    }

    final log = SimpleLogger();
    final orchestrator = BackgroundService.orchestrator;

    // Check if the service is active (for UI status updates)
    final isServiceRunning = await BackgroundService.isServiceRunning();

    try {
      // Only send status update if the service is running (UI might be watching)
      if (isServiceRunning) {
        final service = FlutterBackgroundService();
        service.invoke('status', {'collecting': true});
      }

      log.info('Starting data collection');

      // Collect data
      final success = await orchestrator.collectData();

      log.info('Data collection completed. Success: $success');

      // Update status
      if (isServiceRunning) {
        final service = FlutterBackgroundService();
        service.invoke('status', {
          'collecting': false,
          'success': success,
          'lastCollection': DateTime.now().toIso8601String(),
        });
      }

      // Update success state
      await prefs.setBool(_lastCollectionResultKey, success);

      // Schedule the next run
      await BackgroundService._scheduleOneTimeTask();

      return true;
    } catch (e) {
      log.severe('Error in background task: $e');

      // Update failure state
      await prefs.setBool(_lastCollectionResultKey, false);

      // Send error status if service is running
      if (isServiceRunning) {
        final service = FlutterBackgroundService();
        service.invoke('status', {
          'collecting': false,
          'error': e.toString(),
        });
      }

      // Even on error, schedule the next run with backoff
      await BackgroundService._scheduleOneTimeTask();

      return false;
    }
  });
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

  // Access shared preferences to get the collection frequency
  final prefs = await SharedPreferences.getInstance();
  int collectionFrequencyMinutes = prefs.getInt(_collectionFrequencyKey) ?? _defaultFrequency;

  // Update service notification content
  if (service is AndroidServiceInstance) {
    service.setForegroundNotificationInfo(
      title: 'Nissan Leaf Battery Tracker',
      content: 'Running in background, collecting every $collectionFrequencyMinutes minutes',
    );
  }

  // Handle service lifecycle events
  service.on('stopService').listen((event) {
    log.info('Stopping background service');
    Workmanager().cancelAll();
    service.stopSelf();
  });

  service.on('updateFrequency').listen((event) async {
    if (event != null && event['minutes'] != null) {
      collectionFrequencyMinutes = event['minutes'];
      log.info('Updated collection frequency to $collectionFrequencyMinutes minutes');

      // Save the new frequency
      await prefs.setInt(_collectionFrequencyKey, collectionFrequencyMinutes);

      // Cancel existing tasks and schedule a new one with the updated frequency
      await Workmanager().cancelAll();
      await BackgroundService._scheduleOneTimeTask();

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
    // Run directly for immediate feedback instead of scheduling through WorkManager
    await BackgroundService.manualCollect();
  });

  // Keep service alive
  service.invoke('started', {});
}
