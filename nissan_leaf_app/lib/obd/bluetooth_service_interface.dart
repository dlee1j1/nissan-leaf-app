// lib/obd/bluetooth_service.dart
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// Interface for Bluetooth operations
///
/// This abstraction allows for dependency injection and easier testing
/// by decoupling the BluetoothDeviceManager from direct FlutterBluePlus dependencies.
abstract class BluetoothServiceInterface {
  /// Check if the Bluetooth adapter is on
  Future<bool> isBluetoothOn();

  /// Turn on the Bluetooth adapter if possible
  Future<void> turnOnBluetooth();

  /// Scan for Bluetooth devices
  ///
  /// [timeout] - Duration to scan
  /// [nameFilters] - Optional list of device names to filter by
  /// Returns a list of scan results
  Future<List<ScanResult>> scanForDevices({
    Duration timeout,
    List<String> nameFilters,
  });

  /// Connect to a Bluetooth device
  ///
  /// [device] - The device to connect to
  /// Returns true if connection was successful
  Future<bool> connectToDevice(BluetoothDevice device);

  /// Disconnect from a device
  ///
  /// [device] - The device to disconnect from
  Future<void> disconnectDevice(BluetoothDevice device);

  /// Get the current connection state for a device
  Stream<BluetoothConnectionState> connectionStateStream(BluetoothDevice device);

  /// Discover services for a connected device
  ///
  /// [device] - The connected device
  /// Returns a list of discovered services
  Future<List<BluetoothService>> discoverServices(BluetoothDevice device);
}

/// Real implementation of BluetoothService using FlutterBluePlus
class FlutterBluetoothService implements BluetoothServiceInterface {
  @override
  Future<bool> isBluetoothOn() async {
    final state = await FlutterBluePlus.adapterState.first;
    return state == BluetoothAdapterState.on;
  }

  @override
  Future<void> turnOnBluetooth() async {
    await FlutterBluePlus.turnOn();
  }

  @override
  Future<List<ScanResult>> scanForDevices({
    Duration timeout = const Duration(seconds: 15),
    List<String> nameFilters = const [],
  }) async {
    final deviceMap = <String, ScanResult>{};

    // Set up the scan results listener
    final subscription = FlutterBluePlus.scanResults.listen((results) {
      for (var result in results) {
        deviceMap[result.device.remoteId.str] = result;
      }
    });

    try {
      // Start the scan with the given parameters
      await FlutterBluePlus.startScan(
        timeout: timeout,
        withNames: nameFilters.isNotEmpty ? nameFilters : [],
      );

      // Wait for scan to complete
      await FlutterBluePlus.isScanning.where((val) => val == false).first;

      return deviceMap.values.toList();
    } finally {
      subscription.cancel();
    }
  }

  @override
  Future<bool> connectToDevice(BluetoothDevice device) async {
    try {
      await device.connect(timeout: const Duration(seconds: 5));
      return await device.connectionState.first == BluetoothConnectionState.connected;
    } catch (e) {
      return false;
    }
  }

  @override
  Future<void> disconnectDevice(BluetoothDevice device) async {
    await device.disconnect();
  }

  @override
  Stream<BluetoothConnectionState> connectionStateStream(BluetoothDevice device) {
    return device.connectionState;
  }

  @override
  Future<List<BluetoothService>> discoverServices(BluetoothDevice device) async {
    return device.discoverServices();
  }
}
