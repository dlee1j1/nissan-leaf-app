// lib/background_service.dart
import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simple_logger/simple_logger.dart';
import 'data_orchestrator.dart';
import 'package:location/location.dart' as loc;

// Key constants for shared preferences
const String collectionFrequencyKey = 'collection_frequency_minutes';
const int defaultFrequency = 15; // 15 minutes default

// Add a compile-time constant to choose the collection method
// ignore: constant_identifier_names
const bool USE_LOCATION_BASED_COLLECTION = true; // Set to false to use timer-based
// ignore: constant_identifier_names
const double LOCATION_DISTANCE_FILTER = 800.0; // meters (approx 0.5 miles)

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
  Duration _waitBetweenCollections = Duration(minutes: defaultFrequency);
  Completer<void>? _sleepCompleter;
  Timer? _sleepTimer;
  Duration _baseInterval = Duration(minutes: defaultFrequency);

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
  int frequencyMinutes = prefs.getInt(collectionFrequencyKey) ?? defaultFrequency;

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
