// lib/background_service.dart
import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:simple_logger/simple_logger.dart';
import 'data_orchestrator.dart';
import 'package:location/location.dart' as loc;

// Key constants for shared preferences
const String _serviceEnabledKey = 'background_service_enabled';
const String _collectionFrequencyKey = 'collection_frequency_minutes';
const int _defaultFrequency = 15; // 15 minutes default

// Add a compile-time constant to choose the collection method
// ignore: constant_identifier_names
const bool USE_LOCATION_BASED_COLLECTION = true; // Set to false to use timer-based
// ignore: constant_identifier_names
const double LOCATION_DISTANCE_FILTER = 800.0; // meters (approx 0.5 miles)

/// UI-side controller for managing the background service
class BackgroundServiceController {
  // Static reference to FlutterBackgroundService for communication
  static var _service = FlutterBackgroundService();
  static final _log = SimpleLogger();
  static bool _isSupported = _initializeIsSupported();

  // Dummy controllers for unsupported platforms
  static final _dummyStatusController = StreamController<Map<String, dynamic>?>.broadcast();

  // Platform support flag - centralized check
  static bool _initializeIsSupported() {
    try {
      return Platform.isAndroid || Platform.isIOS;
    } catch (e) {
      // If Platform is not available (e.g., on web), assume not supported
      return false;
    }
  }

  @visibleForTesting
  static setIsSupportedForTest(bool b) => _isSupported = b;

  @visibleForTesting
  static setFlutterBackgroundServiceForTest(FlutterBackgroundService service) => _service = service;

  /// Initialize the service controller
  static Future<void> initialize() async {
    if (!_isSupported) {
      _log.info('Background service not supported on this platform');
      return;
    }

    try {
      // Configure how the service will appear and behave
      await _service.configure(
        androidConfiguration: AndroidConfiguration(
          onStart: backgroundServiceEntryPoint,
          autoStart: false,
          isForegroundMode: true,
          notificationChannelId: 'nissan_leaf_battery_tracker',
          initialNotificationTitle: 'Nissan Leaf Battery Tracker',
          initialNotificationContent: 'Initializing...',
          foregroundServiceNotificationId: 888,
        ),
        iosConfiguration: IosConfiguration(
          autoStart: false,
          onForeground: backgroundServiceEntryPoint,
          onBackground: onIosBackground,
        ),
      );

      // Request necessary permissions
      await _requestPermissions();
    } catch (e) {
      _log.severe('Error initializing background service: $e');
      rethrow;
    }
  }

  /// Request necessary permissions for the background service
  static Future<void> _requestPermissions() async {
    void requestUngrantedPermissions(Permission p) async {
      PermissionStatus result = await p.status;
      if (result != PermissionStatus.granted) result = await p.request();
      if (result != PermissionStatus.granted) {
        throw ("Permission not granted: $p.");
      }
    }

    if (!_isSupported) return;

    for (Permission p in [
      Permission.notification,
      Permission.bluetooth,
      Permission.bluetoothConnect,
      Permission.bluetoothScan,
      Permission.location,
    ]) {
      requestUngrantedPermissions(p);
    }
  }

  /// Start the background service
  static Future<bool> startService() async {
    // Save the service state
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_serviceEnabledKey, true);

    if (_isSupported) {
      _log.info('Starting background service');
      return await _service.startService();
    } else {
      return false;
    }
  }

  /// Stop the background service
  static Future<void> stopService() async {
    if (!_isSupported) {
      _log.info('Background service not supported on this platform');
      return;
    }

    // Save the service state
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_serviceEnabledKey, false);

    _log.info('Stopping background service');
    _service.invoke('stopService');
  }

  /// Check if the service is running
  static Future<bool> isServiceRunning() async {
    if (!_isSupported) {
      return false;
    }

    return await _service.isRunning();
  }

  /// Get the service stream for status updates
  static Stream<Map<String, dynamic>?> getStatusStream() {
    if (!_isSupported) {
      return _dummyStatusController.stream;
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

    if (!_isSupported) {
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

  /// Request a manual data collection
  static Future<void> requestManualCollection() async {
    if (!_isSupported) {
      _log.info('Background service not supported on this platform');
      return;
    }

    if (await isServiceRunning()) {
      _service.invoke('manualCollect');
    }
  }
}

/// Background service implementation that runs in the background process
class BackgroundService {
  // Instance variables
  final SimpleLogger _log = SimpleLogger();
  final DirectOBDOrchestrator _orchestrator;
  final ServiceInstance _service;

  loc.Location? _locationService;
  StreamSubscription<loc.LocationData>? _locationSubscription;

  // Collection control fields
  bool _keepGoing = false;
  Duration _waitBetweenCollections = Duration(minutes: _defaultFrequency);
  Completer<void>? _sleepCompleter;
  Timer? _sleepTimer;
  Duration _baseInterval = Duration(minutes: _defaultFrequency);

  /// Create a new BackgroundService
  BackgroundService(
    this._service, {
    DirectOBDOrchestrator? orchestrator,
    loc.Location? locationService,
  })  : _orchestrator = orchestrator ?? DirectOBDOrchestrator(),
        _locationService = locationService;

  /// Set up location-based collection
  Future<void> setupLocationBasedCollection() async {
    try {
      // Initialize location service
      _locationService ??= loc.Location();

      // Check if location service is enabled
      bool serviceEnabled = await _locationService!.serviceEnabled();
      if (!serviceEnabled) {
        serviceEnabled = await _locationService!.requestService();
        if (!serviceEnabled) {
          _log.warning('Location services not enabled');
          return;
        }
      }

      // Check location permission
      var permissionStatus = await _locationService!.hasPermission();
      if (permissionStatus == loc.PermissionStatus.denied) {
        permissionStatus = await _locationService!.requestPermission();
        if (permissionStatus != loc.PermissionStatus.granted) {
          _log.warning('Location permission not granted');
          return;
        }
      }

      // Configure location service
      await _locationService!.changeSettings(
          accuracy: loc.LocationAccuracy.balanced,
          interval: 10000, // 10 seconds minimum between updates
          distanceFilter: LOCATION_DISTANCE_FILTER);

      // Start listening for location changes
      _locationSubscription = _locationService!.onLocationChanged
          .listen((locationData) => _onLocationChanged(locationData));
      _log.info('Location-based collection enabled with ${LOCATION_DISTANCE_FILTER}m filter');
    } catch (e) {
      _log.severe('Error setting up location-based collection: $e');
    }
  }

  /// Handle location changes
  void _onLocationChanged(loc.LocationData locationData) {
    _log.info(
        'Significant location change detected: ${locationData.latitude}, ${locationData.longitude}');

    // Trigger data collection
    collectData();
  }

  /// Collection functionality
  Future<bool> collectData() async {
    try {
      _log.info('Collecting battery data');
      // Let the orchestrator handle the collection process
      return await _orchestrator.collectData();
    } catch (e, stackTrace) {
      _log.severe('Error collecting data: $e\n$stackTrace');
      _service.invoke('status', {'error': e.toString(), 'collecting': false});
      return false;
    }
  }

  /// Calculate next sleep duration
  Duration computeNextDuration(Duration current, Duration base, bool success) {
    const Duration maxDelay = Duration(minutes: 5);
    if (base > maxDelay) return base; // if base is large anyway, don't need to do backoff
    Duration next;
    if (success) {
      next = base;
    } else {
      next = (current * 2 < maxDelay) ? current * 2 : maxDelay;
    }
    return next;
  }

  /// Start timer-based collection
  Future<void> startTimerCollection(int frequencyMinutes) async {
    if (USE_LOCATION_BASED_COLLECTION) {
      _log.info('Using location-based collection instead of timer');
      await setupLocationBasedCollection();
      return;
    }

    _baseInterval = Duration(minutes: frequencyMinutes);
    _waitBetweenCollections = _baseInterval;
    _keepGoing = true;

    while (_keepGoing) {
      bool success = await collectData();
      var next = computeNextDuration(_waitBetweenCollections, _baseInterval, success);
      _log.info('Going to sleep. Waking up in ${next.inMinutes} minutes.');
      _waitBetweenCollections = next;

      // Use a completer that can be completed early
      _sleepCompleter = Completer<void>();
      _sleepTimer = Timer(next, () {
        if (_sleepCompleter != null && !_sleepCompleter!.isCompleted) {
          _sleepCompleter!.complete();
        }
      });

      // Wait for either the timer to finish or manual interruption
      await _sleepCompleter!.future;
    }
  }

  /// Reset the collection timer
  void kickTimer() {
    if (_sleepCompleter != null && !_sleepCompleter!.isCompleted) {
      _log.info('Resetting collection cycle');
      _sleepTimer?.cancel();
      _sleepCompleter!.complete(); // This will wake up the sleeping loop
    }
  }

  /// Stop timer-based collection
  void stopTimerCollection() {
    _keepGoing = false;
    kickTimer(); // turn off the timer
  }

  /// Update collection frequency
  void updateCollectionFrequency(int minutes) {
    _baseInterval = Duration(minutes: minutes);
    _log.info('Updated collection frequency to $minutes minutes');

    // Update notification
    if (_service is AndroidServiceInstance) {
      _service.setForegroundNotificationInfo(
        title: 'Nissan Leaf Battery Tracker',
        content: 'Running in background, collecting every $minutes minutes',
      );
    }

    // Restart timer if needed
    if (!_keepGoing) {
      startTimerCollection(minutes);
    } else {
      kickTimer();
    }
  }

  /// Handle manual collection request
  Future<void> handleManualCollect() async {
    if (_keepGoing) {
      _log.info('Resetting collection cycle due to manual collection');
      kickTimer();
    } else {
      await collectData();
    }
  }

  /// Clean up resources
  void cleanup() {
    _locationSubscription?.cancel();
    _locationSubscription = null;
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _keepGoing = false;
    if (_sleepCompleter != null && !_sleepCompleter!.isCompleted) {
      _sleepCompleter!.complete();
    }
    _orchestrator.dispose();
  }

  @visibleForTesting
  DirectOBDOrchestrator get orchestrator => _orchestrator;
}

/// iOS background handler - needed for iOS support
@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  return true;
}

/// Main service entry point - this runs when the service starts
@pragma('vm:entry-point')
void backgroundServiceEntryPoint(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();

  final log = SimpleLogger();
  log.info('Background service started');

  // Create a new background service instance
  final backgroundService = BackgroundService(service);

  // Set up logging to forward to UI
  log.onLogged = (message, info) {
    service.invoke('log', {'message': message});
  };

  // Get collection frequency
  final prefs = await SharedPreferences.getInstance();
  int frequencyMinutes = prefs.getInt(_collectionFrequencyKey) ?? _defaultFrequency;

  // Update notification
  if (service is AndroidServiceInstance) {
    service.setForegroundNotificationInfo(
      title: 'Nissan Leaf Battery Tracker',
      content: 'Running in background, collecting every $frequencyMinutes minutes',
    );
  }

  // Set up status forwarding
  backgroundService.orchestrator.statusStream.listen((status) {
    service.invoke('status', status);
  });

  // Set up event handlers
  service.on('stopService').listen((event) {
    log.info('Stopping background service');
    backgroundService.stopTimerCollection();
    backgroundService.cleanup();
    service.stopSelf();
  });

  service.on('updateFrequency').listen((event) {
    if (event != null && event['minutes'] != null) {
      backgroundService.updateCollectionFrequency(event['minutes']);
    }
  });

  service.on('manualCollect').listen((event) async {
    await backgroundService.handleManualCollect();
  });

  // Start collection
  await backgroundService.startTimerCollection(frequencyMinutes);

  // Keep service alive
  service.invoke('started', {});
}
