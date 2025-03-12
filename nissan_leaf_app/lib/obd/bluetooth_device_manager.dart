// lib/obd/bluetooth_device_manager.dart
import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:nissan_leaf_app/async_safety.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simple_logger/simple_logger.dart';
import 'package:permission_handler/permission_handler.dart';

import 'bluetooth_service_interface.dart';
import '../obd/obd_controller.dart';
import '../obd/obd_command.dart';

// Constants for Bluetooth connectivity
// ignore: constant_identifier_names
const SERVICE_UUID = "0000ffe0-0000-1000-8000-00805f9b34fb";
// ignore: constant_identifier_names
const CHARACTERISTIC_UUID = "0000ffe1-0000-1000-8000-00805f9b34fb";

/// A singleton manager class that handles all Bluetooth operations for OBD connectivity
class BluetoothDeviceManager {
  // Singleton pattern
  static final BluetoothDeviceManager _instance = BluetoothDeviceManager._internal();
  static BluetoothDeviceManager get instance => _instance;
  BluetoothDeviceManager._internal();

  // Allow dependency injection for testing
  BluetoothServiceInterface _bluetoothService = FlutterBluetoothService();
  @visibleForTesting
  void setBluetoothServiceForTesting(BluetoothServiceInterface bluetoothService) {
    _bluetoothService = bluetoothService;
  }

  final _log = SimpleLogger();

  // State variables
  BluetoothDevice? _connectedDevice;
  BluetoothCharacteristic? _characteristic;
  ObdController? _obdController;
  bool _isConnecting = false;
  bool _isInitialized = false;

  // Error tracking
  String? _lastErrorMessage;
  int _consecutiveFailures = 0;
  final Map<String, DeviceErrorStats> _deviceErrorStats = {};
  String? get lastError => _lastErrorMessage;
  int get consecutiveFailures => _consecutiveFailures;

  /// Record connection errors for analysis
  void _recordConnectionError(BluetoothDevice device, String error) {
    if (!_deviceErrorStats.containsKey(device.remoteId.str)) {
      _deviceErrorStats[device.remoteId.str] = DeviceErrorStats();
    }
    _deviceErrorStats[device.remoteId.str]!.recordError(error);
  }

  /// Get error statistics for a device
  @visibleForTesting
  DeviceErrorStats? getDeviceErrorStats(String deviceId) {
    return _deviceErrorStats[deviceId];
  }

  // Stream controllers for status updates
  final _connectionStatusController = StreamController<ConnectionStatus>.broadcast();
  Stream<ConnectionStatus> get connectionStatus => _connectionStatusController.stream;

  // Getters
  BluetoothDevice? get connectedDevice => _connectedDevice;
  ObdController? get obdController => _obdController;
  bool get isConnected => _connectedDevice != null && _obdController != null;
  bool get isConnecting => _isConnecting;

  /// Initialize the device manager
  Future<void> initialize() async {
    if (_isInitialized) return;

    _log.info('Initializing BluetoothDeviceManager');

    // Request necessary permissions if on a platform that needs them
    await _requestPermissions();

    // Load last known device
    await _loadSavedDeviceInfo();

    _isInitialized = true;
    _log.info('BluetoothDeviceManager initialized');
  }

  /// Request all required permissions for Bluetooth operation
  Future<void> _requestPermissions() async {
    // Only request permissions on platforms that require them
    if (Platform.isAndroid || Platform.isIOS) {
      _log.info('Requesting Bluetooth permissions');
      for (var permission in [
        Permission.bluetooth,
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.location,
      ]) {
        var isGranted = await permission.status.isGranted;
        if (!isGranted) await permission.request();
      }
    } else {
      _log.info('Current platform does not require explicit Bluetooth permissions');
    }
  }

  /// Begin scanning for Bluetooth devices
  Future<List<ScanResult>> scanForDevices({
    Duration timeout = const Duration(seconds: 15),
    List<String> nameFilters = const ["OBDBLE"],
  }) async {
    if (!_isInitialized) await initialize();

    _log.info('Starting Bluetooth scan for devices...');
    _updateStatus(ConnectionStatus.scanning);

    try {
      // Ensure Bluetooth is on
      final isOn = await _bluetoothService.isBluetoothOn();
      if (!isOn) {
        _log.info('Bluetooth is off, attempting to turn on');
        await _bluetoothService.turnOnBluetooth();
      }

      // Start the scan
      final results = await _bluetoothService.scanForDevices(
        timeout: timeout,
        nameFilters: nameFilters,
      );

      _log.info('Bluetooth scan completed. Found ${results.length} devices');
      _updateStatus(ConnectionStatus.scanComplete);
      return results;
    } catch (e) {
      _log.warning('Error during device scan: $e');
      _updateStatus(ConnectionStatus.error, 'Scan error: $e');
      rethrow;
    }
  }

  /// Connect to a specific Bluetooth device
  Future<bool> connectToDevice(BluetoothDevice device) async {
    if (!_isInitialized) await initialize();

    if (_isConnecting) {
      _log.warning('Already connecting to a device, ignoring request');
      return false;
    }

    if (_connectedDevice != null) {
      _log.info('Disconnecting from current device before connecting to new one');
      await disconnect();
    }

    _isConnecting = true;
    _updateStatus(ConnectionStatus.connecting, 'Connecting to ${device.platformName}...');

    try {
      // Attempt to connect with retry logic
      const maxRetries = 3;
      const pauseBetweenRetry = Duration(milliseconds: 500);
      var attempts = 0;
      bool connected = false;

      while (!connected && attempts < maxRetries) {
        attempts++;
        try {
          connected = await _bluetoothService.connectToDevice(device);
          if (!connected) {
            _log.info('Connection attempt $attempts failed. Device refused connection.');
          }
        } catch (e) {
          _log.info('Connection attempt $attempts failed. $e');
        }

        // If not connected and we still have retries left, wait before trying again
        if (!connected && attempts < maxRetries) {
          await Future.delayed(pauseBetweenRetry);
        }
      }

      // If all retries failed, throw error
      if (!connected) {
        throw Exception('Failed to connect after $maxRetries attempts');
      }

      _connectedDevice = device;
      _updateStatus(
        ConnectionStatus.connected,
        'Connected to ${device.platformName}. Initializing...',
      );

      // Discover services
      var services = await _bluetoothService.discoverServices(device);
      _log.info('Found ${services.length} services');

      // Find our target service
      var targetService = services.firstWhere(
        (s) => s.uuid.toString() == SERVICE_UUID.substring(4, 8),
        orElse: () {
          _log.warning('Target service $SERVICE_UUID not found');
          throw Exception('Required OBD service not found');
        },
      );

      _log.info('Using service: ${targetService.uuid}');

      // Get the characteristic for read/write
      _characteristic = targetService.characteristics.firstWhere(
        (c) => c.uuid.toString() == CHARACTERISTIC_UUID.substring(4, 8),
        orElse: () {
          throw Exception('Required OBD characteristic not found');
        },
      );

      _log.info('Using characteristic ${_characteristic!.uuid}');

      // Create and initialize ObdController
      _obdController = ObdController(_characteristic!);
      await _obdController!.initialize();

      // Set controller for OBD commands
      OBDCommand.setObdController(_obdController!);

      // Test connection with probe command
      await OBDCommand.probe.run();

      // Save device info for future reconnection
      await _saveDeviceInfo(device);

      _updateStatus(ConnectionStatus.ready, 'Device ready');
      _log.info('Successfully connected to OBD device: ${device.platformName}');

      // Reset failure counters on successful connection
      _consecutiveFailures = 0;
      if (_deviceErrorStats.containsKey(device.remoteId.str)) {
        _deviceErrorStats[device.remoteId.str]!.resetConsecutiveFailures();
      }

      return true;
    } catch (e) {
      _consecutiveFailures++;
      _lastErrorMessage = 'Error connecting to device: $e';
      _log.severe(_lastErrorMessage!);
      _updateStatus(ConnectionStatus.error, _lastErrorMessage);

      // Record device-specific error
      _recordConnectionError(device, e.toString());

      // Clean up if connection failed
      if (_connectedDevice != null) {
        try {
          await _bluetoothService.disconnectDevice(_connectedDevice!);
        } catch (_) {}
        _connectedDevice = null;
      }

      _characteristic = null;
      _obdController = null;

      return false;
    } finally {
      _isConnecting = false;
    }
  }

  /// Attempt to reconnect to the last known device
  Future<bool> _reconnectToSavedDevice() async {
    if (!_isInitialized) await initialize();

    if (_connectedDevice != null) {
      _log.info('Already connected to a device');
      return true;
    }

    final prefs = await SharedPreferences.getInstance();
    final savedDeviceId = prefs.getString('obd_device_id');

    if (savedDeviceId == null) {
      _log.info('No saved device found');
      return false;
    }

    try {
      _log.info('Attempting to reconnect to saved device: $savedDeviceId');

      // Create device from ID
      final device = BluetoothDevice(remoteId: DeviceIdentifier(savedDeviceId));

      return await connectToDevice(device);
    } catch (e) {
      _log.warning('Failed to reconnect to saved device: $e');
      return false;
    }
  }

  /// Disconnect from the current device
  Future<void> disconnect() async {
    if (_connectedDevice == null) {
      _log.info('No device connected, nothing to disconnect');
      return;
    }

    _log.info('Disconnecting from device: ${_connectedDevice!.platformName}');
    _updateStatus(ConnectionStatus.disconnecting);

    try {
      await _bluetoothService.disconnectDevice(_connectedDevice!);
      _log.info('Device disconnected');
    } catch (e) {
      _log.warning('Error disconnecting: $e');
    } finally {
      _connectedDevice = null;
      _characteristic = null;
      _obdController = null;
      _updateStatus(ConnectionStatus.disconnected);
    }
  }

  // we wrap autoConnectToObd so only once instance of it ever runs.
  //   this implementation is a little more complicated than a simple "isRunning" bool
  //   guard but it allows all callers to get the same result.
  //  It also exposes the future which we can export for testing purposes.
  //
  final SingleFlight<bool> _autoConnectGuard = SingleFlight<bool>();
  Future<bool> autoConnectToObd() {
    return _autoConnectGuard.run(() => _autoConnectToObd());
  }

  Future<bool> _autoConnectToObd() async {
    // If no saved device or reconnection failed, scan for devices
    try {
      // scan is cheap - so start with that
      final results = await scanForDevices(timeout: Duration(seconds: 2));

      // If no devices at all, bail out early
      if (results.isEmpty) {
        _log.info('No Bluetooth devices in range, skipping connection attempts');
        return false;
      }

      // Check if our saved device is in the scan results
      final prefs = await SharedPreferences.getInstance();
      final savedDeviceId = prefs.getString('obd_device_id');

      // Sort devices to prioritize those with OBD-related names
      var potentialDevices = results.toList();
      potentialDevices.sort((a, b) {
        bool aHasObdName =
            a.device.platformName.contains("OBD") || a.device.platformName.contains("ELM");
        bool bHasObdName =
            b.device.platformName.contains("OBD") || b.device.platformName.contains("ELM");

        if (savedDeviceId != null) {
          if (a.device.remoteId.str == savedDeviceId) return -1;
          if (b.device.remoteId.str == savedDeviceId) return 1;
        }
        if (aHasObdName && !bHasObdName) return -1;
        if (!aHasObdName && bHasObdName) return 1;
        return 0;
      });

      // Try to connect to each device and test initialization
      for (var result in potentialDevices) {
        _log.info('Attempting connection to ${result.device.platformName}');

        // Attempt connection
        if (await connectToDevice(result.device)) {
          // Test if we can successfully run a probe command
          try {
            // Just use the command's run() method directly
            var probeResult = await OBDCommand.probe.run();

            // If we get any response, we likely have a valid OBD device
            if (probeResult.isNotEmpty) {
              _log.info('Successfully connected to OBD device: ${result.device.platformName}');
              return true;
            } else {
              _log.info('Device responded but returned empty probe result, trying next device');
              await disconnect();
            }
          } catch (e) {
            _log.info('Device failed OBD probe test: $e');
            await disconnect();
          }
        }
      }

      _log.warning('No valid OBD devices found after scanning');
      return false;
    } catch (e) {
      _log.warning('Auto-connection error: $e');
      return false;
    }
  }

  Future<Map<String, dynamic>?> collectCarData({bool disconnectAfter = true}) async {
    if (!isConnected) {
      try {
        bool connected = await autoConnectToObd();
        if (!connected) {
          _log.warning('Failed to connect to OBD device, cannot collect data');
          return null;
        }
      } catch (e) {
        _log.warning('Error connecting to OBD device: $e');
        return null;
      }
    }

    try {
      // Collect data using existing commands
      final batteryData = await OBDCommand.lbc.run();
      final rangeData = await OBDCommand.rangeRemaining.run();

      if (batteryData.isEmpty) {
        return null;
      }

      // Optionally disconnect
      if (disconnectAfter) {
        await disconnect();
      }

      return {...batteryData, ...rangeData, 'timestamp': DateTime.now().millisecondsSinceEpoch};
    } catch (e) {
      _log.severe('Error collecting data: $e');
      return null;
    }
  }

  /// Send a debug OBD command and return the response
  Future<Map<String, dynamic>> sendDebugCommand(String command, String header) async {
    if (!isConnected) {
      _log.warning('No connection available for debug command');
      return {'error': 'No connection available'};
    }

    _log.info('Sending debug command: $command with header: $header');

    try {
      // Create a simple command class
      final debugCommand = _DebugCommand(command: command, header: header);

      // Set the current controller
      debugCommand.setController(_obdController!);

      // Run the command
      final result = await debugCommand.run();
      _log.info('Debug command result: $result');

      return {'result': result};
    } catch (e) {
      _log.severe('Error running debug command: $e');
      return {'error': e.toString()};
    }
  }

  /// Run a specific OBD command
  Future<Map<String, dynamic>> runCommand(OBDCommand command) async {
    if (!isConnected) {
      _log.warning('No connection available for command: ${command.name}');
      return {};
    }

    try {
      // Ensure the controller is set
      OBDCommand.setObdController(_obdController!);

      // Run the command
      return await command.run();
    } catch (e) {
      _log.severe('Error running command ${command.name}: $e');
      return {};
    }
  }

  /// Run all available commands
  Future<Map<String, Map<String, dynamic>>> runAllCommands() async {
    if (!isConnected) {
      _log.warning('No connection available for running all commands');
      return {};
    }

    final results = <String, Map<String, dynamic>>{};
    final commands = OBDCommand.getAllCommands();

    for (final command in commands) {
      try {
        final result = await runCommand(command);
        results[command.name] = result;
      } catch (e) {
        _log.warning('Error running command ${command.name}: $e');
        results[command.name] = {'error': e.toString()};
      }
    }

    return results;
  }

  /// Save device information for future reconnection
  Future<void> _saveDeviceInfo(BluetoothDevice device) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('obd_device_id', device.remoteId.str);
    await prefs.setString('obd_device_name', device.platformName);
    _log.info('Saved device info: ${device.platformName} (${device.remoteId.str})');
  }

  /// Load saved device information
  Future<void> _loadSavedDeviceInfo() async {
    final prefs = await SharedPreferences.getInstance();
    final savedDeviceId = prefs.getString('obd_device_id');
    final savedDeviceName = prefs.getString('obd_device_name');

    if (savedDeviceId != null) {
      _log.info('Found saved device: $savedDeviceName ($savedDeviceId)');
    }
  }

  /// Update connection status and notify listeners
  void _updateStatus(ConnectionStatus status, [String? message]) {
    _log.info('Connection status updated: $status ${message != null ? "- $message" : ""}');
    _connectionStatusController.add(status);
  }

  /// Clean up resources
  void dispose() {
    _connectionStatusController.close();
  }
}

/// Connection status enum
enum ConnectionStatus {
  disconnected,
  scanning,
  scanComplete,
  connecting,
  connected,
  ready,
  disconnecting,
  error,
}

/// Track error statistics for a specific device
class DeviceErrorStats {
  int totalErrors = 0;
  int totalConnections = 0;
  int consecutiveFailures = 0;
  int successfulConnections = 0;
  Map<String, int> errorTypeCount = {};

  void recordError(String error) {
    totalErrors++;
    consecutiveFailures++;
    errorTypeCount[error] = (errorTypeCount[error] ?? 0) + 1;
  }

  void recordSuccess() {
    totalConnections++;
    successfulConnections++;
    consecutiveFailures = 0;
  }

  void resetConsecutiveFailures() {
    consecutiveFailures = 0;
  }

  bool get hasSuccessfulConnections => successfulConnections > 0;

  double get successRate => totalConnections > 0 ? successfulConnections / totalConnections : 0;

  bool get hasTimeoutErrors => errorTypeCount.keys.any((e) => e.toLowerCase().contains('timeout'));
}

/// A simple debug command class for testing
class _DebugCommand extends OBDCommand {
  _DebugCommand({required super.command, required super.header})
      : super(name: 'debug', description: 'Debug Command');

  void setController(ObdController controller) {
    OBDCommand.setObdController(controller);
  }

  @override
  Map<String, dynamic> decode(List<int> response) {
    return {'raw_data': response};
  }
}
