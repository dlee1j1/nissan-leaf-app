import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:simple_logger/simple_logger.dart';

import '../obd/obd_controller.dart';
import '../obd/obd_command.dart';
import '../components/log_viewer.dart';
import '../components/obd_commands_panel.dart';

// Constants for Bluetooth connectivity
// ignore: constant_identifier_names
const SERVICE_UUID = "0000ffe0-0000-1000-8000-00805f9b34fb";
// ignore: constant_identifier_names
const CHARACTERISTIC_UUID = "0000ffe1-0000-1000-8000-00805f9b34fb";

final _log = SimpleLogger();

class BleScanPage extends StatefulWidget {
  const BleScanPage({super.key});

  @override
  State<BleScanPage> createState() => _BleScanPageState();
}

class _BleScanPageState extends State<BleScanPage> {
  final Map<String, ScanResult> deviceMap = {};
  ScanResult? obdDevice;
  bool isScanning = false;
  bool isConnecting = false; // Track connection state
  String connectionStatus = 'Disconnected';
  BluetoothDevice? connectedDevice;
  ObdController? obdController;

  @override
  void initState() {
    super.initState();
    requestPermissions().then((_) => startScan());
  }

  Future<void> requestPermissions() async {
    await Permission.bluetooth.request();
    await Permission.bluetoothScan.request();
    await Permission.bluetoothConnect.request();
    await Permission.location.request();
  }

  void startScan() async {
    setState(() {
      isScanning = true;
      obdDevice = null;
    });

    try {
      // Check if Bluetooth is on
      if (await FlutterBluePlus.adapterState.first == BluetoothAdapterState.unknown) {
        // for IOS
        await Future.delayed(const Duration(seconds: 1));
      }
      if (await FlutterBluePlus.adapterState.first != BluetoothAdapterState.on) {
        _log.info('Bluetooth is off');
        await FlutterBluePlus.turnOn();
      }

      // Set up the listener before starting scan
      FlutterBluePlus.scanResults.listen((results) {
        setState(() {
          // Update map with latest results, overwriting existing entries
          for (var result in results) {
            deviceMap[result.device.remoteId.str] = result;
          }
        });
      });

      _log.info('Starting Bluetooth scan...');
      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 15),
        withNames: ["OBDBLE"],
      );

      // Wait for scan to complete
      await FlutterBluePlus.isScanning.where((val) => val == false).first;
      _log.info('Bluetooth scan completed.');
    } catch (e) {
      _log.warning('Scan error: $e');
    } finally {
      setState(() => isScanning = false);
    }
  }

  void connectToDevice(BluetoothDevice device) async {
    const maxRetries = 3;
    if (isConnecting) {
      return; // Ignore further clicks if already connecting
    }

    setState(() {
      isConnecting = true;
      connectionStatus = 'Connecting to ${device.platformName}...';
    });

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

    _log.info('Connected to device: ${device.platformName}');
    setState(() {
      connectionStatus = 'Connected. Initializing ${device.platformName}...';
      connectedDevice = device;
    });

    try {
      var services = await device.discoverServices();
      _log.finest('Found ${services.length} services:');

      // Log all discovered services
      for (var service in services) {
        _log.info('Service: ${service.uuid}');
      }

      // Try to find our target service
      var targetService = services.firstWhere(
        (s) => s.uuid.toString() == SERVICE_UUID.substring(4, 8),
        orElse: () {
          _log.warning('Target service $SERVICE_UUID not found');
          return services.first; // Return first service as fallback
        },
      );

      _log.info('Using service: ${targetService.uuid}');

      // Get the characteristic for read/write
      var characteristic = targetService.characteristics
          .firstWhere((c) => c.uuid.toString() == CHARACTERISTIC_UUID.substring(4, 8));

      _log.finest('Using characteristic ${characteristic.uuid}');

      // Create ObdController instance
      final controller = ObdController(characteristic);
      _log.info('Found services - initializing odb controller...');
      await controller.initialize();
      // Send a command and get the response
      OBDCommand.setObdController(controller);
      await OBDCommand.probe.run();

      setState(() {
        connectionStatus = 'Connected';
        obdController = controller;
      });
    } catch (e) {
      _log.severe('Connection error: $e');
      setState(() {
        connectionStatus = 'Error: ${e.toString()}';
      });
    } finally {
      setState(() {
        isConnecting = false;
      });
    }
  }

  Future<void> disconnectDevice() async {
    if (connectedDevice != null) {
      _log.info('Disconnecting from device: ${connectedDevice!.platformName}...');
      await connectedDevice!.disconnect();
      connectedDevice = null; // Clear the connected device
      obdController = null; // Clear the controller
      setState(() {
        connectionStatus = 'Disconnected';
      });
      _log.info('Device disconnected.');
    }
  }

  @override
  Widget build(BuildContext context) {
    // Convert map values to list for ListView
    final devices = deviceMap.values.toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Nissan Leaf OBD Scanner'), actions: [
        ElevatedButton(
          onPressed: () => Navigator.pushNamed(context, '/obd_test'),
          child: const Text('OBD Test'),
        ),
        if (obdController != null)
          ElevatedButton(
            onPressed: () => Navigator.pushNamed(
              context,
              '/dashboard',
              arguments: obdController,
            ),
            child: const Text('Dashboard'),
          ),
      ]),
      body: Column(
        children: [
          // Status section
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              children: [
                Text('Status: $connectionStatus'),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  isScanning ? 'Scanning...' : 'Scan complete',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                ElevatedButton(
                  onPressed: isScanning ? null : startScan,
                  child: const Text('Rescan'),
                ),
              ],
            ),
          ),
          // Device List Section
          if (connectedDevice != null && !isConnecting)
            Expanded(
              child: ObdCommandsPanel(),
            )
          else
            Expanded(
              flex: 2,
              child: ListView.builder(
                itemCount: devices.length,
                itemBuilder: (context, index) {
                  final device = devices[index];
                  return ListTile(
                    title: Text(device.device.platformName.isEmpty
                        ? 'Unknown Device'
                        : device.device.platformName),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('ID: ${device.device.remoteId}'),
                        Text('RSSI: ${device.rssi}'),
                        Text('Services: ${device.advertisementData.serviceUuids.join(", ")}'),
                        if (device.advertisementData.manufacturerData.isNotEmpty)
                          Text('Manufacturer: ${device.advertisementData.manufacturerData}'),
                      ],
                    ),
                    isThreeLine: true,
                    onTap: isConnecting
                        ? null
                        : () => connectToDevice(device.device), // Disable if connecting
                  );
                },
              ),
            ),
          // Log Viewer Section
          Expanded(
            flex: 1,
            child: LogViewer(), // Pass logs to LogViewer
          ),

          // Disconnect Button
          if (connectedDevice != null)
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  ElevatedButton(
                    onPressed: disconnectDevice,
                    child: const Text('Disconnect'),
                  ),
                  ElevatedButton(
                    onPressed: () => Navigator.pushNamed(
                      context,
                      '/dashboard',
                      arguments: obdController,
                    ),
                    child: const Text('Open Dashboard'),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
