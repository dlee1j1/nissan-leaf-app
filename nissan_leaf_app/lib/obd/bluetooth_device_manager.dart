// lib/obd/bluetooth_device_manager.dart
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:nissan_leaf_app/async_safety.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simple_logger/simple_logger.dart';

import 'bluetooth_service_interface.dart';
import '../obd/obd_controller.dart';
import '../obd/obd_command.dart';
import 'connection_status.dart';

// Constants for Bluetooth connectivity
// ignore: constant_identifier_names
const SERVICE_UUID = "0000ffe0-0000-1000-8000-00805f9b34fb";
// ignore: constant_identifier_names
const CHARACTERISTIC_UUID = "0000ffe1-0000-1000-8000-00805f9b34fb";

/// Manages all Bluetooth operations for OBD connectivity.
///
/// A plain, normally-constructible class - not a baked-in singleton. [instance]
/// is a global accessor over the app's one real instance, shared by its two
/// production call sites (`OBDConnector`, `DashboardPage`); it's convenience,
/// not a constraint. Tests construct their own via `BluetoothDeviceManager()`
/// directly, so each test starts from genuinely clean state instead of
/// needing to remember to reset every field a shared instance might carry
/// over from the previous test (see #9, which did the same for
/// BackgroundService - this class had the identical problem).
class BluetoothDeviceManager {
  BluetoothDeviceManager();

  static final BluetoothDeviceManager instance = BluetoothDeviceManager();

  // Allow dependency injection for testing
  BluetoothServiceInterface _bluetoothService = FlutterBluetoothService();
  @visibleForTesting
  void setBluetoothServiceForTesting(BluetoothServiceInterface bluetoothService) {
    _bluetoothService = bluetoothService;
  }

  ObdController Function(dynamic params) _obdControllerFactory = (params) => ObdController(params);
  @visibleForTesting
  void setObdControllerFactoryForTesting(ObdController Function(dynamic params) factory) {
    _obdControllerFactory = factory;
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

  /// Why the most recent scan/connect/collect attempt failed, or null if the
  /// most recent one succeeded (or nothing has run yet). Cleared at the start
  /// of [scanForDevices] and on a successful [collectCarData], set at each
  /// failure point in between - see issue #3.
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

    // Load last known device
    await _loadSavedDeviceInfo();

    _isInitialized = true;
    _log.info('BluetoothDeviceManager initialized');
  }

  /// Begin scanning for Bluetooth devices
  Future<List<ScanResult>> scanForDevices({
    Duration timeout = const Duration(seconds: 15),
    List<String> nameFilters = const ["OBDBLE"],
  }) async {
    if (!_isInitialized) await initialize();

    _log.info('Starting Bluetooth scan for devices...');
    _updateStatus(ConnectionStatus.scanning);
    // Cleared here, not just on failure, so a stale message from a previous
    // scan can't be misread as the reason for *this* one.
    _lastErrorMessage = null;

    try {
      // Ensure Bluetooth is on
      final isOn = await _bluetoothService.isBluetoothOn();
      if (!isOn) {
        _log.info('Bluetooth is off, attempting to turn on');
        try {
          await _bluetoothService.turnOnBluetooth();
        } catch (e) {
          _log.warning('Could not turn on Bluetooth: $e');
          _lastErrorMessage = 'Bluetooth unavailable: $e';
          _updateStatus(ConnectionStatus.error, 'Bluetooth unavailable');
          return []; // Return empty list instead of throwing
        }
      }

      // Start the scan
      try {
        final results = await _bluetoothService.scanForDevices(
          timeout: timeout,
          nameFilters: nameFilters,
        );

        _log.info('Bluetooth scan completed. Found ${results.length} devices');
        _updateStatus(ConnectionStatus.scanComplete);
        return results;
      } catch (e) {
        // e.g. a platform scan-throttle rejection (Android limits how often an
        // app may start a scan). Without this, the caller sees the same empty
        // list as "genuinely nothing in range" - indistinguishable from the
        // outside. See issue #3.
        _log.warning('Error during device scan: $e');
        _lastErrorMessage = 'Scan error: $e';
        _updateStatus(ConnectionStatus.error, 'Scan error: $e');
        return []; // Return empty list instead of throwing
      }
    } catch (e) {
      _log.warning('Unexpected error in scanForDevices: $e');
      _lastErrorMessage = 'Unexpected scan error: $e';
      _updateStatus(ConnectionStatus.error, 'Unexpected error: $e');
      return []; // Return empty list for any error
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
      //   use this convoluted method to enable mocking of ObdController in tests
      //    i.e., in test you would use ObdController.setFactory(MockObdControllerFactory);
      _obdController = _obdControllerFactory(_characteristic!);
      await _obdController!.initialize();

      // Set controller for OBD commands
      OBDCommand.setObdController(_obdController!);

      // Test connection with probe command. probe is a real command to the
      // vehicle's BMS ECU (header 797), not a benign ELM327 self-test - an
      // empty response means the dongle answered but the vehicle bus didn't,
      // which is exactly as unusable as a thrown exception here.
      final probeResult = await OBDCommand.probe.run();
      if (probeResult.isEmpty) {
        throw Exception('Probe returned empty response');
      }

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

      // Clean up if connection failed. Must be awaited: the finally below
      // clears _isConnecting, and a caller retrying on `false` (autoConnectToObd
      // loops over devices) would otherwise start the next connect while this
      // BLE teardown is still in flight.
      await disconnect();
      return false;
    } finally {
      _isConnecting = false;
    }
    // try and catch both return; Dart's body_might_complete_normally makes a
    // fall-through here a compile error, so no explicit tripwire is needed.
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

      // If no devices at all, bail out early. scanForDevices already set
      // _lastErrorMessage if the scan itself errored (e.g. platform
      // scan-throttle) - only fall back to the generic message when it
      // didn't, so we don't overwrite a more specific reason with a vaguer
      // one. Otherwise "scan was rejected" and "genuinely nothing in range"
      // are indistinguishable from here on. See issue #3.
      if (results.isEmpty) {
        _lastErrorMessage ??= 'No Bluetooth devices in range';
        _log.info('${_lastErrorMessage!}, skipping connection attempts');
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

      // Try to connect to each device. connectToDevice already probes the
      // vehicle bus as part of connecting (including rejecting an empty
      // response) - re-probing here used to send the same diagnostic-session
      // command to the car's ECU a second time back to back, which a real
      // vehicle ECU may not answer the same way twice in a row. See #3: this
      // redundant probe is the leading suspect for "found the dongle every
      // cycle, never actually got data".
      for (var result in potentialDevices) {
        _log.info('Attempting connection to ${result.device.platformName}');
        if (await connectToDevice(result.device)) {
          _log.info('Successfully connected to OBD device: ${result.device.platformName}');
          return true;
        }
        // connectToDevice already logged/recorded the specific reason
        // (_lastErrorMessage) and disconnected; try the next candidate.
      }

      _lastErrorMessage ??= 'Found ${potentialDevices.length} device(s) but none matched as OBD';
      _log.warning('No valid OBD devices found after scanning');
    } catch (e) {
      _lastErrorMessage = 'Auto-connection error: $e';
      _log.warning('Auto-connection error: $e');
    }

    // if we got here, we didn't find a valid device. disconnect and return false
    await disconnect();
    return false;
  }

  Future<Map<String, dynamic>?> collectCarData() async {
    if (!isConnected) {
      try {
        bool connected = await autoConnectToObd();
        if (!connected) {
          // autoConnectToObd already set _lastErrorMessage with the specific
          // reason (no devices in range, scan error, no OBD match, ...) and
          // already disconnected on its own failure path.
          _log.warning('Failed to connect to OBD device, cannot collect data');
          return null;
        }
      } catch (e) {
        _lastErrorMessage = 'Error connecting to OBD device: $e';
        _log.warning('Error connecting to OBD device: $e');
        return null;
      }
    }

    // Deliberately no `finally { disconnect(); }` here (see #17) - a
    // successful cycle stays connected so the *next* cycle can skip the
    // scan+connect+probe round-trip entirely via the `if (!isConnected)`
    // check above. Re-entrancy is guarded elsewhere (collectData()'s
    // SingleFlight, autoConnectToObd()'s SingleFlight, connectToDevice()'s
    // _isConnecting), not by this method always tearing the link down.
    // Disconnect deliberately on failure - a broken command is reason enough
    // to distrust this connection and force a clean reconnect next time,
    // and it's what turns a live OBDBLE link back into an ACL_DISCONNECTED
    // the receiver could someday act on (it doesn't yet - see #13).
    try {
      final batteryData = await OBDCommand.lbc.run();
      final rangeData = await OBDCommand.rangeRemaining.run();

      if (batteryData.isEmpty) {
        _lastErrorMessage = 'OBD device returned no battery data';
        await disconnect();
        return null;
      }

      _lastErrorMessage = null; // this cycle succeeded - stay connected
      return {...batteryData, ...rangeData, 'timestamp': DateTime.now().millisecondsSinceEpoch};
    } catch (e) {
      _lastErrorMessage = 'Error collecting data: $e';
      _log.severe('Error collecting data: $e');
      await disconnect();
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
