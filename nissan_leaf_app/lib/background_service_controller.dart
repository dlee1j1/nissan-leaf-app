// background_service_controller.dart - replacing with foreground task
import 'dart:async';
import 'dart:io';
import 'dart:ui' show PluginUtilities;
import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simple_logger/simple_logger.dart';
import 'background_service.dart';

/// SharedPreferences key for the durable backup of the Dart callback handle
/// - see the doc comment on [BackgroundServiceController.startService] for
/// why this exists. Deliberately not the plugin's own key/prefs file: this
/// must survive `FlutterForegroundTask.stopService()`, which clears the
/// plugin's copy.
const String callbackHandleBackupKey = 'ffg_task_callback_handle_backup';

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
  // First statement, deliberately before anything else - see issue #22 and
  // the doc comment on BackgroundService.markIsolateAlive(). This is the
  // earliest point any Dart code runs in the isolate at all, which is
  // exactly what needs marking: in the #22 zombie case, not even this
  // function's own first log line (a few statements below) ever ran.
  BackgroundService.markIsolateAlive();

  // SimpleLogger is a singleton, but only within the isolate that
  // constructs it - this isolate's copy is distinct from the one main.dart
  // wires up for the UI's LogViewer (see #20 follow-up). Forward every log
  // line to the main isolate over the same message channel used for
  // getStatus/refreshNow so LogViewer can show what the real background
  // service is doing, not just what the UI isolate happens to be doing.
  SimpleLogger().onLogged = (log, info) {
    FlutterForegroundTask.sendDataToMain({'type': 'log', 'message': log});
  };

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
          // No periodic wakeup: scheduling is driven by BackgroundService's own
          // timer, and liveness is tracked in service_heartbeat.log (issue #3).
          eventAction: ForegroundTaskEventAction.nothing(),
          // No boot behaviour: the dongle's BLE presence is the only trigger.
          // See the Decisions section in CLAUDE.md and issue #3.
          autoRunOnBoot: false,
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
    ];

    for (final permission in permissions) {
      final status = await permission.status;
      if (status != PermissionStatus.granted) {
        await permission.request();
      }
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

  /// Start the background service.
  ///
  /// Also backs up the Dart callback handle to our own SharedPreferences key
  /// - see issue #22. `FlutterForegroundTask.startService()` computes a
  /// numeric handle for [backgroundServiceEntryPoint]
  /// (`PluginUtilities.getCallbackHandle`, tied to this specific compiled
  /// binary) and persists it in the plugin's own prefs, which is how
  /// `ObdConnectionReceiver`'s headless REBOOT later finds it with no live
  /// Dart context to hand a function reference to directly. But
  /// `FlutterForegroundTask.stopService()` - which `BackgroundService` calls
  /// on itself as an intentional, routine "probably parked" self-stop after
  /// `maxConsecutiveFailures` - clears that entire prefs entry as a side
  /// effect, callback handle included. Nothing then re-persists it until the
  /// app is next opened by hand, so a headless REBOOT in between (the next
  /// drive) finds a null handle: native still promotes the OS-level
  /// foreground service (nothing checks the handle before doing that) but
  /// silently never asks the engine to run any Dart code at all - no
  /// exception, no crash, no heartbeat, ever. Confirmed directly via a
  /// breadcrumb-patched build of the plugin during the #22 investigation.
  ///
  /// The backup here is computed independently (same deterministic
  /// function, same result) and written to a key of our own that
  /// `stopService()` never touches, so `ObdConnectionReceiver` can restore
  /// it if it ever finds the plugin's own copy missing at REBOOT time - see
  /// `ObdConnectionReceiver.restoreCallbackHandleIfMissing`.
  static Future<bool> startService() async {
    if (_isSupported) {
      _log.info('Starting background service');
      await _foregroundTask.startService(
        notificationTitle: 'Nissan Leaf Battery Tracker',
        notificationText: 'Monitoring battery status',
        callback: backgroundServiceEntryPoint,
      );
      await _backupCallbackHandle();
      return true;
    } else {
      return false;
    }
  }

  /// See the doc comment on [startService].
  static Future<void> _backupCallbackHandle() async {
    try {
      final handle = PluginUtilities.getCallbackHandle(backgroundServiceEntryPoint);
      if (handle == null) {
        _log.warning('Could not compute callback handle to back up');
        return;
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(callbackHandleBackupKey, handle.toRawHandle());
    } catch (e) {
      _log.warning('Failed to back up callback handle: $e');
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

    return await _foregroundTask.isRunningService;
  }

  /// Whether a background isolate is genuinely alive right now - see issue
  /// #22. Complementary to [isServiceRunning]: that only reflects whether
  /// Android promoted the OS-level foreground-service notification, which
  /// (as #22 proved) can be `true` even when no Dart code ever ran.
  /// `isServiceRunning() && !isBackgroundIsolateAlive` is the exact
  /// signature of that bug, detectable instantly - no round trip, no
  /// timeout, since IsolateNameServer's registry is native and answers
  /// synchronously.
  static bool get isBackgroundIsolateAlive => BackgroundService.isIsolateAlive;
}
