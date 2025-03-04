// lib/obd/bluetooth_device_manager.dart
import 'dart:async';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simple_logger/simple_logger.dart';
import 'package:permission_handler/permission_handler.dart';

import '../obd/obd_controller.dart';
import '../obd/obd_command.dart';
import '../obd/mock_obd_controller.dart';

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

  final _log = SimpleLogger();

  // State variables
  BluetoothDevice? _connectedDevice;
  BluetoothCharacteristic? _characteristic;
  ObdController? _obdController;
  bool _isConnecting = false;
  bool _isInitialized = false;
  bool _isInMockMode = false;

  // Stream controllers for status updates
  final _connectionStatusController = StreamController<ConnectionStatus>.broadcast();
  Stream<ConnectionStatus> get connectionStatus => _connectionStatusController.stream;

  // For testing and debug mode
  String? _mockResponseData;
  String? _mockRangeResponseData;

  // Getters
  BluetoothDevice? get connectedDevice => _connectedDevice;
  ObdController? get obdController => _obdController;
  bool get isConnected => _connectedDevice != null && _obdController != null && !_isInMockMode;
  bool get isConnecting => _isConnecting;
  bool get isInMockMode => _isInMockMode;

  /// Initialize the device manager
  Future<void> initialize() async {
    if (_isInitialized) return;

    _log.info('Initializing BluetoothDeviceManager');

    // Request necessary permissions
    await _requestPermissions();

    // Load last known device
    await _loadSavedDeviceInfo();

    _isInitialized = true;
    _log.info('BluetoothDeviceManager initialized');
  }

  /// Request all required permissions for Bluetooth operation
  Future<void> _requestPermissions() async {
    await Permission.bluetooth.request();
    await Permission.bluetoothScan.request();
    await Permission.bluetoothConnect.request();
    await Permission.location.request();
  }

  /// Begin scanning for Bluetooth devices
  Future<List<ScanResult>> scanForDevices({
    Duration timeout = const Duration(seconds: 15),
    List<String> nameFilters = const ["OBDBLE"],
  }) async {
    if (!_isInitialized) await initialize();

    _log.info('Starting Bluetooth scan for devices...');
    _updateStatus(ConnectionStatus.scanning);

    final completer = Completer<List<ScanResult>>();
    final deviceMap = <String, ScanResult>{};

    // Ensure Bluetooth is on
    if (await FlutterBluePlus.adapterState.first == BluetoothAdapterState.unknown) {
      await Future.delayed(const Duration(seconds: 1));
    }
    if (await FlutterBluePlus.adapterState.first != BluetoothAdapterState.on) {
      _log.info('Bluetooth is off, attempting to turn on');
      await FlutterBluePlus.turnOn();
    }

    // Listen for scan results
    final subscription = FlutterBluePlus.scanResults.listen((results) {
      // Update map with latest results
      for (var result in results) {
        deviceMap[result.device.remoteId.str] = result;
      }
    });

    try {
      // Start the scan
      await FlutterBluePlus.startScan(
        timeout: timeout,
        withNames: nameFilters.isNotEmpty ? nameFilters : [],
      );

      // Wait for scan to complete
      await FlutterBluePlus.isScanning.where((val) => val == false).first;
      _log.info('Bluetooth scan completed. Found ${deviceMap.length} devices');

      _updateStatus(ConnectionStatus.scanComplete);
      completer.complete(deviceMap.values.toList());
    } catch (e) {
      _log.warning('Error during device scan: $e');
      _updateStatus(ConnectionStatus.error, 'Scan error: $e');
      completer.completeError(e);
    } finally {
      subscription.cancel();
    }

    return completer.future;
  }

  /// Connect to a specific Bluetooth device
  Future<bool> connectToDevice(BluetoothDevice device) async {
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
      var tries = 0;

      while (await device.connectionState.first != BluetoothConnectionState.connected) {
        try {
          await device.connect(timeout: const Duration(seconds: 5));
        } catch (e) {
          tries++;
          _log.info('Connection attempt $tries failed: $e');
          if (tries >= maxRetries) {
            throw Exception('Failed to connect after $maxRetries attempts');
          }
          await Future.delayed(const Duration(seconds: 2));
        }
      }

      _connectedDevice = device;
      _updateStatus(
          ConnectionStatus.connected, 'Connected to ${device.platformName}. Initializing...');

      // Discover services
      var services = await device.discoverServices();
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
      _characteristic = targetService.characteristics
          .firstWhere((c) => c.uuid.toString() == CHARACTERISTIC_UUID.substring(4, 8), orElse: () {
        throw Exception('Required OBD characteristic not found');
      });

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

      _isInMockMode = false;
      _updateStatus(ConnectionStatus.ready, 'Device ready');
      _log.info('Successfully connected to OBD device: ${device.platformName}');

      return true;
    } catch (e) {
      _log.severe('Error connecting to device: $e');
      _updateStatus(ConnectionStatus.error, 'Connection error: $e');

      // Clean up if connection failed
      if (_connectedDevice != null) {
        try {
          await _connectedDevice!.disconnect();
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
  Future<bool> reconnectToSavedDevice() async {
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
      final device = BluetoothDevice(
        remoteId: DeviceIdentifier(savedDeviceId),
        //   platformName: prefs.getString('obd_device_name') ?? 'Unknown',
      );

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
      await _connectedDevice!.disconnect();
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

  /// Set up mock mode for testing
  void enableMockMode({
    String? mockResponse,
    String? mockRangeResponse,
  }) {
    _log.info('Enabling mock mode');

    // Default responses if none provided
    _mockResponseData = mockResponse ??
        '''
      7BB10356101FFFFF060
      7BB210289FFFFE763FF
      7BB22FFCA4A09584650
      7BB239608383E038700
      7BB24017000239A000C
      7BB25814C00191FB580
      7BB260005FFFFE763FF
      7BB27FFE56501AEFFFF''';

    _mockRangeResponseData = mockRangeResponse ?? '7BB 03 62 0E 24 05 DC';

    // Create mock controller
    final mockController = MockObdController(_mockResponseData!);
    mockController.mockRangeResponse = _mockRangeResponseData;

    // Set up controller
    _obdController = mockController;
    OBDCommand.setObdController(_obdController!);

    _isInMockMode = true;
    _updateStatus(ConnectionStatus.mockMode, 'Using mock data');
  }

  /// Disable mock mode
  void disableMockMode() {
    if (!_isInMockMode) return;

    _log.info('Disabling mock mode');
    _obdController = null;
    _isInMockMode = false;
    _updateStatus(ConnectionStatus.disconnected);
  }

  /// Send a debug OBD command and return the response
  Future<Map<String, dynamic>> sendDebugCommand(String command, String header) async {
    if (!isConnected && !_isInMockMode) {
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
    if (!isConnected && !_isInMockMode) {
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
    if (!isConnected && !_isInMockMode) {
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
  mockMode,
}

/// A simple debug command class for testing
class _DebugCommand extends OBDCommand {
  _DebugCommand({required super.command, required super.header})
      : super(
          name: 'debug',
          description: 'Debug Command',
        );

  void setController(ObdController controller) {
    OBDCommand.setObdController(controller);
  }

  @override
  Map<String, dynamic> decode(List<int> response) {
    return {'raw_data': response};
  }
}
