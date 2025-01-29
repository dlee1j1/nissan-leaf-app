import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'obd_controller.dart';
import 'components/log_viewer.dart';
import 'services/logger.dart'; // Import the Logger service
import 'dart:async'; // Override the global `print` function


const SERVICE_UUID = "0000ffe0-0000-1000-8000-00805f9b34fb";
const CHARACTERISTIC_UUID = "0000ffe1-0000-1000-8000-00805f9b34fb";


void main() {
  runZonedGuarded(
    () {
      runApp(const NissanLeafApp());
    },
    (error, stack) {
      print('Error: $error\n$stack');
    },
    zoneSpecification: ZoneSpecification(
      print: (Zone self, ZoneDelegate parent, Zone zone, String line) {
        parent.print(zone, line); // Print to console
        Logger.instance.log(line); // Log to our viewer
      },
    ),
  );
}

class NissanLeafApp extends StatelessWidget {
  const NissanLeafApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nissan Leaf OBD',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: BleScanPage(), // Pass the logger to the page
    );
  }
}

class BleScanPage extends StatefulWidget {
  const BleScanPage({super.key});

  @override
  State<BleScanPage> createState() => _BleScanPageState();
}

class _BleScanPageState extends State<BleScanPage> {
  final Map<String, ScanResult> deviceMap = {};
  ScanResult? obdDevice;
  bool isScanning = false;
  String connectionStatus = 'Disconnected';
  int? batterySOC;

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
      if (!await FlutterBluePlus.isOn) {
        print('Bluetooth is off'); // This will be intercepted by the overridden `print`
        await FlutterBluePlus.turnOn();
      }

      // Set up the listener before starting scan
      FlutterBluePlus.scanResults.listen((results) {
        setState(() {
          // Update map with latest results, overwriting existing entries
          for (var result in results) {
            deviceMap[result.device.id.id] = result;
          }
        });
      });

      print('Starting Bluetooth scan...'); // This will be intercepted by the overridden `print`
      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 15),
        withNames: ["OBDBLE"],
      );

      // Wait for scan to complete
      await FlutterBluePlus.isScanning.where((val) => val == false).first;
      print('Bluetooth scan completed.'); // This will be intercepted by the overridden `print`
    } catch (e) {
      print('Scan error: $e'); // This will be intercepted by the overridden `print`
    } finally {
      setState(() => isScanning = false);
    }
  }

  void connectToDevice(BluetoothDevice device) async {
    try {
      print('Connecting to device: ${device.name}...'); // This will be intercepted by the overridden `print`
      // Connect to device
      await device.connect(autoConnect: true);

      // Get the target service
      var services = await device.discoverServices();
      var obdService = services.firstWhere((s) => s.uuid.toString() == SERVICE_UUID);

      // Get the characteristic for read/write
      var characteristic = obdService.characteristics.firstWhere(
        (c) => c.uuid.toString() == CHARACTERISTIC_UUID
      );

      // Create ObdController instance
      var obdController = ObdController(characteristic);
      await obdController.initialize();

      print('Connected to device: ${device.name}'); // This will be intercepted by the overridden `print`
      setState(() {
        connectionStatus = 'Connected';
      });
    } catch (e) {
      print('Connection error: $e'); // This will be intercepted by the overridden `print`
      setState(() {
        connectionStatus = 'Error: ${e.toString()}';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Convert map values to list for ListView
    final devices = deviceMap.values.toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Nissan Leaf OBD Scanner')),
      body: Column(
        children: [
          // Status section
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              children: [
                Text('Status: $connectionStatus'),
                if (batterySOC != null) Text('Battery: $batterySOC%'),
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
          Expanded(
            flex: 2,
            child: ListView.builder(
              itemCount: devices.length,
              itemBuilder: (context, index) {
                final device = devices[index];
                return ListTile(
                  title: Text(device.device.name.isEmpty
                      ? 'Unknown Device'
                      : device.device.name),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('ID: ${device.device.id}'),
                      Text('RSSI: ${device.rssi}'),
                      Text('Services: ${device.advertisementData.serviceUuids.join(", ")}'),
                      if (device.advertisementData.manufacturerData.isNotEmpty)
                        Text('Manufacturer: ${device.advertisementData.manufacturerData}'),
                    ],
                  ),
                  isThreeLine: true,
                  onTap: () => connectToDevice(device.device),
                );
              },
            ),
          ),
          // Log Viewer Section
          Expanded(
            flex: 1,
            child: LogViewer(logs: Logger.instance.logs), // Pass logs to LogViewer
          ),
        ],
      ),
    );
  }
}