import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:simple_logger/simple_logger.dart';
import 'package:location/location.dart' as loc;
import 'background_service.dart';

// Key constants for shared preferences
const String _serviceEnabledKey = 'background_service_enabled';

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

    // Check location permission
    var locationService = loc.Location();
    var permissionStatus = await locationService.hasPermission();
    if (permissionStatus == loc.PermissionStatus.denied) {
      permissionStatus = await locationService.requestPermission();
      if (permissionStatus != loc.PermissionStatus.granted) {
        throw ('Location permission not granted');
      }
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
    await prefs.setInt(collectionFrequencyKey, minutes);

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
    return prefs.getInt(collectionFrequencyKey) ?? defaultFrequency;
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
