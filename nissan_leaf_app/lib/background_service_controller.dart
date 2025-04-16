// background_service_controller.dart - replacing with foreground task
import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:simple_logger/simple_logger.dart';
import 'package:location/location.dart' as loc;
import 'background_service.dart';

/// Wrapper class for FlutterForegroundTask static methods to make testing easier
class ForegroundTaskWrapper {
  /// Initialize the foreground task
  Future<void> init({
    required AndroidNotificationOptions androidNotificationOptions,
    required IOSNotificationOptions iosNotificationOptions,
    required ForegroundTaskOptions foregroundTaskOptions,
  }) async {
    FlutterForegroundTask.init(
      androidNotificationOptions: androidNotificationOptions,
      iosNotificationOptions: iosNotificationOptions,
      foregroundTaskOptions: foregroundTaskOptions,
    );
  }

  /// Start the foreground service
  Future<void> startService({
    required String notificationTitle,
    required String notificationText,
    required Function callback,
  }) async {
    await FlutterForegroundTask.startService(
      notificationTitle: notificationTitle,
      notificationText: notificationText,
      callback: callback,
    );
  }

  /// Stop the foreground service
  Future<void> stopService() async {
    await FlutterForegroundTask.stopService();
  }

  /// Check if the service is running
  Future<bool> get isRunningService async {
    return await FlutterForegroundTask.isRunningService;
  }

  /// Check notification permission
  Future<NotificationPermission> checkNotificationPermission() async {
    return await FlutterForegroundTask.checkNotificationPermission();
  }

  /// Request notification permission
  Future<NotificationPermission> requestNotificationPermission() async {
    return await FlutterForegroundTask.requestNotificationPermission();
  }

  /// Check if ignoring battery optimizations
  Future<bool> get isIgnoringBatteryOptimizations async {
    return await FlutterForegroundTask.isIgnoringBatteryOptimizations;
  }

  /// Request ignore battery optimization
  Future<void> requestIgnoreBatteryOptimization() async {
    await FlutterForegroundTask.requestIgnoreBatteryOptimization();
  }

  /// Update service notification
  Future<void> updateService({
    String? notificationTitle,
    String? notificationText,
  }) async {
    await FlutterForegroundTask.updateService(
      notificationTitle: notificationTitle,
      notificationText: notificationText,
    );
  }
}

/// Main entry point for the foreground task
@pragma('vm:entry-point')
void backgroundServiceEntryPoint() {
  // Initialize the task handler
  SimpleLogger().info("BackgroundServiceEntryPoint called!!!");
  FlutterForegroundTask.setTaskHandler(BackgroundService());
}

/// UI-side controller for managing the background service
/// Now implemented using foreground_task plugin
class BackgroundServiceController {
  static final _log = SimpleLogger();
  static bool _isSupported = _initializeIsSupported();
  static ForegroundTaskWrapper _foregroundTask = ForegroundTaskWrapper();

  // Platform support flag - centralized check
  static bool _initializeIsSupported() {
    try {
      return !kIsWeb && (Platform.isAndroid || Platform.isIOS);
    } catch (e) {
      // If Platform is not available (e.g., on web), assume not supported
      return false;
    }
  }

  @visibleForTesting
  static setIsSupportedForTest(bool b) => _isSupported = b;

  @visibleForTesting
  static setForegroundTaskForTest(ForegroundTaskWrapper mock) => _foregroundTask = mock;

  /// Initialize the service controller
  static Future<void> initialize() async {
    if (!_isSupported) {
      _log.info('Background service not supported on this platform');
      return;
    }
    try {
      // Initialize the foreground task
      await _foregroundTask.init(
        androidNotificationOptions: AndroidNotificationOptions(
          channelId: 'nissan_leaf_battery_tracker',
          channelName: 'Nissan Leaf Battery Tracker',
          channelDescription: 'Monitoring battery status',
          channelImportance: NotificationChannelImportance.LOW,
          priority: NotificationPriority.LOW,
        ),
        iosNotificationOptions: const IOSNotificationOptions(
          showNotification: true,
          playSound: false,
        ),
        foregroundTaskOptions: ForegroundTaskOptions(
          eventAction: ForegroundTaskEventAction.repeat(60 * 1000),
          autoRunOnBoot: true,
          allowWifiLock: false,
        ),
      );
      _log.info("successfully initialized foreground system");

      // Request necessary permissions
      await _requestPermissions();
    } catch (e) {
      _log.severe('Error initializing background service: $e');
      // Log the error but don't rethrow it
      // This allows the app to continue running even if the service fails to initialize
    }
  }

  /// Request necessary permissions for the background service
  static Future<void> _requestPermissions() async {
    if (!_isSupported) return;

    // Handle permissions using permission_handler
    final permissions = [
      Permission.notification,
      Permission.bluetooth,
      Permission.bluetoothConnect,
      Permission.bluetoothScan,
      Permission.location,
    ];

    for (final permission in permissions) {
      final status = await permission.status;
      if (status != PermissionStatus.granted) {
        await permission.request();
      }
    }

    // Check location permission
    var locationService = loc.Location();
    var permissionStatus = await locationService.hasPermission();
    if (permissionStatus == loc.PermissionStatus.denied) {
      permissionStatus = await locationService.requestPermission();
    }

    // Android 13+, you need to allow notification permission to display foreground service notification.
    //
    // iOS: If you need notification, ask for permission.
    final NotificationPermission notificationPermission =
        await _foregroundTask.checkNotificationPermission();
    if (notificationPermission != NotificationPermission.granted) {
      await _foregroundTask.requestNotificationPermission();
    }

    if (Platform.isAndroid) {
      // Android 12+, there are restrictions on starting a foreground service.
      //
      // To restart the service on device reboot or unexpected problem, you need to allow below permission.
      if (!await _foregroundTask.isIgnoringBatteryOptimizations) {
        // This function requires `android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` permission.
        await _foregroundTask.requestIgnoreBatteryOptimization();
      }
    }
  }

  /// Start the background service
  static Future<bool> startService() async {
    if (_isSupported) {
      _log.info('Starting background service');
      try {
        await _foregroundTask.startService(
          notificationTitle: 'Nissan Leaf Battery Tracker',
          notificationText: 'Monitoring battery status',
          callback: backgroundServiceEntryPoint,
        );
        return true;
      } catch (e) {
        _log.severe('Error starting background service: $e');
        // Log the error but allow the app to continue
        return false;
      }
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

    _log.info('Stopping background service');
    await _foregroundTask.stopService();
  }

  /// Check if the service is running
  static Future<bool> isServiceRunning() async {
    if (!_isSupported) {
      return false;
    }

    try {
      return await _foregroundTask.isRunningService;
    } catch (e) {
      _log.warning('Error checking if service is running: $e');
      return false;
    }
  }

  /// Setup periodic service health check and restart if needed
  static Timer? _serviceHealthCheckTimer;

  static void setupServiceHealthCheck({Duration checkInterval = const Duration(minutes: 30)}) {
    if (!_isSupported) return;

    // Cancel any existing timer
    _serviceHealthCheckTimer?.cancel();

    // Create a new timer for periodic checks
    _serviceHealthCheckTimer = Timer.periodic(checkInterval, (_) async {
      _log.info('Performing background service health check');

      try {
        bool isRunning = await isServiceRunning();

        if (!isRunning) {
          _log.warning('Background service not running, attempting to restart');

          // First try to initialize if needed
          await initialize();

          // Then try to start the service
          bool started = await startService();

          if (started) {
            _log.info('Successfully restarted background service');
          } else {
            _log.warning('Failed to restart background service');
          }
        } else {
          _log.info('Background service is running correctly');
        }
      } catch (e) {
        _log.severe('Error during service health check: $e');
        // Even if health check fails, we keep the timer running
      }
    });

    _log.info('Service health check scheduled every ${checkInterval.inMinutes} minutes');
  }

  /// Stop the service health check
  static void stopServiceHealthCheck() {
    _serviceHealthCheckTimer?.cancel();
    _serviceHealthCheckTimer = null;
    _log.info('Service health check stopped');
  }
}
