// lib/background_service.dart
import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/foundation.dart' show kIsWeb;
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

enum TriggerType {
  timer,
  movement,
  manual;
}

/// Background service implementation that runs in the background process
class BackgroundService {
  // Instance variables
  final SimpleLogger _log = SimpleLogger();
  final DataOrchestrator _orchestrator;
  final ServiceInstance _service;

  loc.Location? _locationService;
  StreamSubscription<loc.LocationData>? _locationSubscription;

  /// Create a new BackgroundService
  BackgroundService(
    this._service, {
    DataOrchestrator? orchestrator,
    loc.Location? locationService,
  }) : _orchestrator = orchestrator ?? (kIsWeb ? MockDataOrchestrator() : DirectOBDOrchestrator()) {
    // Only set up location service if not on web
    if (!kIsWeb) {
      // Only use or create location service on non-web platforms
      _locationService = locationService ?? loc.Location();
      _setupLocationBasedCollection();
    } else {
      // Ensure locationService is null on web so we never try to use it
      _locationService = null;
    }
  }

  /// Set up location-based collection
  Future<void> _setupLocationBasedCollection() async {
    try {
      if (_locationService == null) {
        _log.warning('Location service not available');
        return;
      }
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
          accuracy: loc.LocationAccuracy.balanced, distanceFilter: LOCATION_DISTANCE_FILTER);
    } catch (e) {
      _log.severe('Error setting up location-based collection: $e');
    }
  }

  // Collection control fields
  Duration _waitBetweenCollections = Duration(minutes: defaultFrequency);
  Duration _baseInterval = Duration(minutes: defaultFrequency);
  TriggerType _lastTrigger = TriggerType.timer;
  bool _lastCollectionSuccess = true;
  static const Duration maxDelay = Duration(minutes: 30);
  static const Duration maxDelayBeforeGPS = Duration(minutes: 10);
  Timer _timer = Timer(Duration.zero, () {});

  /// Collection functionality
  @visibleForTesting
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
  @visibleForTesting
  Duration computeNextDuration(Duration current, Duration base, bool success) {
    if (base > maxDelay) return base; // if base is large anyway, don't need to do backoff
    Duration next;
    if (success) {
      next = base;
    } else {
      next = (current * 2 < maxDelay) ? current * 2 : maxDelay;
    }
    return next;
  }

  /// Sets up the collection strategy using both timer and location triggers
  /// This is called after each collection to schedule the next one
  ///
  /// If the last collection was manually triggered or location-based,
  ///  reset to the base interval; otherwise calculate the next interval
  ///  based on success/failure of the last timer-triggered collection (exponential backoff)
  ///
  /// If we're waiting a long time (due to backoff from failures),
  /// also enable location-based collection on supported platforms.
  /// This gives us a second chance to collect data if we happen to get on a vehicle that moves.
  ///
  /// Note that if the location based collection triggers, the reset slows down the
  /// collection frequency to the base interval which keeps disables the location trigger for a while.
  /// This avoids the situation where we are sitting in a moving vehicle and the OBD controller
  /// is not available.
  Future<void> setupActivityTracking() async {
    try {
      if (_lastTrigger != TriggerType.timer) {
        _waitBetweenCollections = _baseInterval;
      } else {
        _waitBetweenCollections =
            computeNextDuration(_waitBetweenCollections, _baseInterval, _lastCollectionSuccess);
      }

      // Schedule the next collection
      _timer = Timer(_waitBetweenCollections, () {
        execute(TriggerType.timer);
      });

      if (_waitBetweenCollections >= maxDelayBeforeGPS && (Platform.isAndroid || Platform.isIOS)) {
        // Start listening for location changes if we are at max wait interval
        _locationSubscription =
            _locationService!.onLocationChanged.listen((_) => execute(TriggerType.movement));
        _log.info('Location-based collection enabled with ${LOCATION_DISTANCE_FILTER}m filter');
      }
    } catch (e) {
      _log.severe('Error setting up activity recognition: $e');
    }
  }

  Future<void> stop() async {
    _timer.cancel();
    if (_locationSubscription != null) {
      await _locationSubscription!.cancel();
      _locationSubscription = null;
    }
  }

  /// Main collection execution method
  /// This is called by timer, location change, or manual triggers
  ///
  /// Collection Logic:
  /// 1. Prevent multiple simultaneous collections with _executing flag
  /// 2. Record the trigger type for future interval calculations
  /// 3. Stop existing triggers (timer and location)
  /// 4. Perform the actual data collection
  /// 5. Set up the next collection cycle based on results
  bool _executing = false;
  Future<void> execute(TriggerType trigger) async {
    if (_executing) return; // drop the activity if we get here multiple times
    _executing = true;
    _lastTrigger = trigger;
    await stop();
    _lastCollectionSuccess = await collectData(); // actual work
    await setupActivityTracking();
    _executing = false;
  }

  /// Update collection frequency
  void updateCollectionFrequency(int minutes) {
    _baseInterval = Duration(minutes: minutes);
    if (_waitBetweenCollections < _baseInterval) {
      _waitBetweenCollections = _baseInterval;
    }
    _log.info('Updated collection frequency to $minutes minutes');

    // Update notification
    if (_service is AndroidServiceInstance) {
      _service.setForegroundNotificationInfo(
        title: 'Nissan Leaf Battery Tracker',
        content: 'Running in background, collecting every $minutes minutes',
      );
    }

    // kick off a redo
    execute(TriggerType.manual);
  }

  /// Clean up resources
  void cleanup() {
    stop();
    _orchestrator.dispose();
  }

  @visibleForTesting
  DataOrchestrator get orchestrator => _orchestrator;
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
    backgroundService.cleanup();
    service.stopSelf();
  });

  service.on('updateFrequency').listen((event) {
    if (event != null && event['minutes'] != null) {
      backgroundService.updateCollectionFrequency(event['minutes']);
    }
  });

  service.on('manualCollect').listen((event) async {
    await backgroundService.execute(TriggerType.manual);
  });

  // Start collection
  await backgroundService.execute(TriggerType.manual);

  // Keep service alive
  service.invoke('started', {});
}
