// File: lib/obd/obd_connector.dart
import 'dart:async';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:meta/meta.dart';
import 'bluetooth_device_manager.dart';
import 'connection_status.dart';

/// A simplified facade for OBD device connectivity and data collection.
///
/// This class provides a streamlined interface to the most commonly used
/// functionality of the Bluetooth device manager, hiding the more specialized
/// methods that are only needed in specific UI scenarios.
///
/// Usage:
/// ```dart
/// final connector = OBDConnector();
///
/// // Connect to an OBD device automatically
/// bool connected = await connector.autoConnectToObd();
///
/// // Collect data
/// final data = await connector.collectCarData();
/// ```
///
/// For specialized connection UIs, see the [OBDConnectorAdvanced] extension.
class OBDConnector {
  final BluetoothDeviceManager _deviceManager;

  /// Creates a standard connector with the default BluetoothDeviceManager instance.
  factory OBDConnector() {
    return OBDConnector._internal(BluetoothDeviceManager.instance);
  }

  /// Creates a connector with a custom device manager implementation.
  ///
  /// This constructor is primarily used for testing purposes.
  @visibleForTesting
  factory OBDConnector.forTesting({
    required BluetoothDeviceManager deviceManager,
  }) {
    return OBDConnector._internal(deviceManager);
  }

  /// Internal constructor with direct device manager injection.
  OBDConnector._internal(this._deviceManager);

  /// Initialize the OBD connector.
  ///
  /// This should be called before using any other methods.
  Future<void> initialize() => _deviceManager.initialize();

  /// Attempts to connect to a nearby OBD device automatically.
  ///
  /// Returns true if connection was successful, false otherwise.
  Future<bool> autoConnectToObd() => _deviceManager.autoConnectToObd();

  /// Collects data from the connected vehicle.
  ///
  /// Returns a map of vehicle data if successful, null otherwise.
  Future<Map<String, dynamic>?> collectCarData() => _deviceManager.collectCarData();

  /// Returns true if currently connected to an OBD device.
  bool get isConnected => _deviceManager.isConnected;

  /// Stream of connection status updates.
  Stream<ConnectionStatus> get connectionStatus => _deviceManager.connectionStatus;

  /// Exposes the underlying device manager for testing purposes.
  ///
  /// This should never be used in production code.
  @visibleForTesting
  BluetoothDeviceManager get deviceManager => _deviceManager;
}

/// Extension providing advanced methods for specialized UI screens.
///
/// These methods are intentionally separated as an extension to discourage
/// their use in general application code.
///
/// Usage:
/// ```dart
/// // Import the extension where needed
/// import 'obd/obd_connector.dart';
///
/// // Then in connection UI screens:
/// final connector = OBDConnector();
/// final devices = await connector.scanForDevices();
/// ```
extension OBDConnectorAdvanced on OBDConnector {
  /// ADVANCED: Check if the connector is currently in the process of connecting.
  ///
  /// This property is primarily used in UI code to show connection progress.
  bool get isConnecting => _deviceManager.isConnecting;

  /// ADVANCED: Connects to a specific Bluetooth device.
  ///
  /// This method should only be used in specialized UIs like manual device
  /// selection screens. Most application code should use [autoConnectToObd()] instead.
  Future<bool> connectToDevice(BluetoothDevice device) => _deviceManager.connectToDevice(device);

  /// ADVANCED: Disconnects from the currently connected device.
  ///
  /// This method should only be used when explicit disconnection is required.
  Future<void> disconnect() => _deviceManager.disconnect();

  /// ADVANCED: Scans for nearby OBD devices.
  ///
  /// This method should only be used in specialized UIs like device discovery screens.
  Future<List<ScanResult>> scanForDevices({
    Duration timeout = const Duration(seconds: 15),
  }) =>
      _deviceManager.scanForDevices(timeout: timeout);
}
