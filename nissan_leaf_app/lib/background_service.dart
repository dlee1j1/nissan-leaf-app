// background_service.dart - replacing with foreground task
import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:location/location.dart' as loc;
import 'package:meta/meta.dart';
import 'package:simple_logger/simple_logger.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'data_orchestrator.dart';

// Key constants for shared preferences
const int defaultFrequency = 1; // 1 minute default

// Add a compile-time constant to choose the collection method
// ignore: constant_identifier_names
const double LOCATION_DISTANCE_FILTER = 1600.0; // meters (approx 1 miles)

enum TriggerType {
  timer,
  movement,
  manual;
}

/// Handler that implements the background service logic
class BackgroundService extends TaskHandler implements DataOrchestrator {
  // Singleton instance
  static BackgroundService? _instance;

  // Instance variables
  final SimpleLogger _log = SimpleLogger();
  DataOrchestrator _orchestrator;
  final bool _createdOrchestrator;
  loc.Location? _locationService;
  StreamSubscription<loc.LocationData>? _locationSubscription;

  // Collection control fields
  Duration _waitBetweenCollections = Duration(minutes: defaultFrequency);
  Duration _baseInterval = Duration(minutes: defaultFrequency);
  TriggerType _lastTrigger = TriggerType.timer;
  bool _lastCollectionSuccess = true;
  static const Duration maxDelay = Duration(minutes: 30);
  static const Duration maxDelayBeforeGPS = Duration(minutes: 10);
  Timer? _timer;
  bool _executing = false;

  /// Factory constructor that returns the singleton instance
  factory BackgroundService({
    DataOrchestrator? orchestrator,
    loc.Location? locationService,
  }) {
    _instance ??= BackgroundService._internal(
      orchestrator: orchestrator,
      locationService: locationService,
    );
    return _instance!;
  }

  @visibleForTesting
  void setOrchestratorForTesting(DataOrchestrator orchestrator) {
    _orchestrator = orchestrator;
  }

  /// Private constructor for singleton pattern
  BackgroundService._internal({
    DataOrchestrator? orchestrator,
    loc.Location? locationService,
  })  : _orchestrator = orchestrator ?? (kIsWeb ? MockDataOrchestrator() : DirectOBDOrchestrator()),
        _createdOrchestrator = (orchestrator != null) {
    // Only set up location service if not on web
    if (!kIsWeb) {
      // Only use or create location service on non-web platforms
      _locationService = locationService ?? loc.Location();
    } else {
      // Ensure locationService is null on web so we never try to use it
      _locationService = null;
    }
  }

  @override
  Stream<Map<String, dynamic>> get statusStream => _orchestrator.statusStream;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    try {
      _log.info('Background service started - starter: ${starter.name})');

      // Check if this might be a restart after a crash
      final prefs = await SharedPreferences.getInstance();
      final lastShutdownStr = prefs.getString('service_last_shutdown');

      // Reset state to ensure we start clean
      _executing = false;

      if (lastShutdownStr != null) {
        try {
          final lastShutdown = DateTime.parse(lastShutdownStr);
          if (DateTime.now().difference(lastShutdown).inMinutes < 5) {
            // This is likely a quick restart - could be a crash recovery
            _log.warning('Service restarted soon after shutdown - possible crash recovery');
            // Be more conservative with collection frequency
            int currentFreq = _baseInterval.inMinutes;
            if (currentFreq < 5) {
              _baseInterval = Duration(minutes: 5);
              _log.info(
                  'Adjusted base interval to ${_baseInterval.inMinutes} minutes for stability');
            }
          }
        } catch (e) {
          _log.warning('Error parsing last shutdown time: $e');
        }
      }

      // Set up location service if on mobile
      if (!kIsWeb) {
        try {
          await _setupLocationBasedCollection();
        } catch (e) {
          _log.warning('Error setting up location collection: $e');
          // Continue even if location setup fails
        }
      }

      // Start collection
      try {
        await execute(TriggerType.manual);
      } catch (e) {
        _log.severe('Error during initial collection: $e');
        // Continue service operation even if initial collection fails
      }

      // Update notification
      try {
        FlutterForegroundTask.updateService(
          notificationTitle: 'Nissan Leaf Battery Tracker',
          notificationText: 'Collecting every ${_waitBetweenCollections.inMinutes} minutes',
        );
      } catch (e) {
        _log.warning('Error updating notification: $e');
      }
    } catch (e, stackTrace) {
      _log.severe('Fatal error in onStart: $e\n$stackTrace');
      // Don't let errors in onStart prevent service from running
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

  /// Collection functionality
  @override
  Future<bool> collectData() async {
    await execute(TriggerType.manual);
    return _lastCollectionSuccess;
  }

  /// Calculate next sleep duration
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
  Future<void> setupActivityTracking() async {
    try {
      await stop();
      _waitBetweenCollections =
          computeNextDuration(_waitBetweenCollections, _baseInterval, _lastCollectionSuccess);

      // Schedule the next collection
      _timer = Timer(_waitBetweenCollections, () {
        execute(TriggerType.timer);
      });

      //
      if (_waitBetweenCollections >= maxDelayBeforeGPS &&
          _lastTrigger != TriggerType.movement &&
          (Platform.isAndroid || Platform.isIOS)) {
        // Start listening for location changes if we are at max wait interval
        _locationSubscription =
            _locationService!.onLocationChanged.listen((_) => execute(TriggerType.movement));
        _log.info('Location-based collection enabled with ${LOCATION_DISTANCE_FILTER}m filter');
      }

      // Update notification
      FlutterForegroundTask.updateService(
        notificationTitle: 'Nissan Leaf Battery Tracker',
        notificationText:
            'Wait ${_waitBetweenCollections.inMinutes} mins. $_lastTrigger success ${_success[_lastTrigger]}/${_tries[_lastTrigger]}',
      );
    } catch (e) {
      _log.severe('Error setting up activity tracking: $e');
    }
  }

  Future<void> stop() async {
    _timer?.cancel();
    if (_locationSubscription != null) {
      await _locationSubscription!.cancel();
      _locationSubscription = null;
    }
  }

  // stats
  final Map<TriggerType, int> _success = {
    TriggerType.manual: 0,
    TriggerType.movement: 0,
    TriggerType.timer: 0
  };
  final Map<TriggerType, int> _tries = {
    TriggerType.manual: 0,
    TriggerType.movement: 0,
    TriggerType.timer: 0
  };
  void computeStats(TriggerType trigger) {
    int tries = _tries[trigger] ?? 0;
    _tries[trigger] = tries + 1;
    int success = _success[trigger] ?? 0;
    _success[trigger] = success + (_lastCollectionSuccess ? 1 : 0);
    _log.info("Stats:$trigger - ${_success[trigger]}/${_tries[trigger]}");
  }

  /// Main collection execution method
  Future<void> execute(TriggerType trigger) async {
    if (_executing) return; // drop the activity if we get here multiple times

    _executing = true;
    try {
      _log.info("Executing based on $trigger");
      _lastTrigger = trigger;
      await stop();

      // Update notification to show collection in progress
      try {
        FlutterForegroundTask.updateService(
          notificationTitle: 'Nissan Leaf Battery Tracker',
          notificationText: 'Collecting battery data...',
        );
      } catch (e) {
        _log.warning('Failed to update notification: $e');
        // Continue even if notification update fails
      }

      // actual work
      try {
        _lastCollectionSuccess = await _orchestrator.collectData().onError((e, stackTrace) {
          _log.severe('Error collecting data: $e\n$stackTrace');

          // Update notification with error information
          String errorMessage = 'Error collecting data';
          if (e.toString().contains('bluetooth') || e.toString().contains('Bluetooth')) {
            errorMessage = 'Bluetooth connection unavailable';
          }

          try {
            FlutterForegroundTask.updateService(
              notificationTitle: 'Nissan Leaf Battery Tracker',
              notificationText: '$errorMessage. Will retry later.',
            );
          } catch (notifError) {
            _log.warning('Failed to update error notification: $notifError');
          }

          return false;
        });
      } catch (e, stackTrace) {
        _log.severe('Unexpected error in execute: $e\n$stackTrace');
        _lastCollectionSuccess = false;

        // Update notification with error information
        try {
          FlutterForegroundTask.updateService(
            notificationTitle: 'Nissan Leaf Battery Tracker',
            notificationText: 'Service error. Will retry in a few minutes.',
          );
        } catch (notifError) {
          _log.warning('Failed to update error notification: $notifError');
        }
      }

      computeStats(trigger);
      await setupActivityTracking();
    } catch (e, stackTrace) {
      _log.severe('Fatal error in background service execute: $e\n$stackTrace');
      _lastCollectionSuccess = false;
      // Attempt to recover by scheduling next collection
      try {
        await setupActivityTracking();
      } catch (setupError) {
        _log.severe('Failed to set up next collection: $setupError');
      }
    } finally {
      _executing = false; // Always reset execution flag
    }
  }

  /// Update collection frequency
  void updateCollectionFrequency(int minutes) {
    _baseInterval = Duration(minutes: minutes);
    if (_waitBetweenCollections < _baseInterval) {
      _waitBetweenCollections = _baseInterval;
    }
    _log.info('Updated collection frequency to $minutes minutes');

    // Update notification
    FlutterForegroundTask.updateService(
      notificationTitle: 'Nissan Leaf Battery Tracker',
      notificationText: 'Running in background, collecting every $minutes minutes',
    );

    // Kick off a new collection
    execute(TriggerType.manual);
  }

  int _calls = 0;
  @override
  Future<void> onRepeatEvent(DateTime timestamp) async {
    // This is called periodically by the foreground task framework
    // We're using our own timer for more precise control
    _calls++;
    _log.info("Repeated event: $_calls");
  }

  @override
  void dispose() {
    try {
      stop().then((_) {
        // Ensure _orchestrator is disposed only if we created it
        if (_createdOrchestrator) {
          try {
            _orchestrator.dispose();
          } catch (e) {
            _log.warning('Error disposing orchestrator: $e');
          }
        }
      }).catchError((e) {
        _log.severe('Error during stop in dispose: $e');
      });
    } catch (e) {
      _log.severe('Error during dispose: $e');
      // Don't rethrow to avoid crashing the service
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    _log.info('Background service being destroyed');
    try {
      // Save any persistent state that might be needed on restart
      final prefs = await SharedPreferences.getInstance();
      prefs.setString('service_last_shutdown', DateTime.now().toIso8601String());

      // Clean up resources
      dispose();
    } catch (e, stackTrace) {
      _log.severe('Error during onDestroy: $e\n$stackTrace');
      // Don't let exceptions in onDestroy crash the service
    }
  }
}
