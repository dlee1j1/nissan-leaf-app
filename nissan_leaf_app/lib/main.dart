import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'obd_controller.dart';
import 'obd_command.dart';
import 'components/log_viewer.dart';
import 'services/logger.dart'; // Import the Logger service
import 'dart:async'; // Override the global `print` function
import 'dart:convert';

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
       // developer.log(line); // Add this for platform logging
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
  bool isConnecting = false; // Track connection state
  String connectionStatus = 'Disconnected';
  BluetoothDevice? connectedDevice;
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
            deviceMap[result.device.remoteId.id] = result;
          }
        });
      });

      print('Starting Bluetooth scan...'); 
      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 15),
        withNames: ["OBDBLE"],
      );

      // Wait for scan to complete
      await FlutterBluePlus.isScanning.where((val) => val == false).first;
      print('Bluetooth scan completed.'); 
    } catch (e) {
      print('Scan error: $e'); 
    } finally {
      setState(() => isScanning = false);
    }
  }


  void connectToDevice(BluetoothDevice device) async {
    const MAX_RETRIES = 3;
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
        print('Connection attempt ${tries} failed: $e');
        if (tries >= MAX_RETRIES) {
          throw Exception('Failed to connect after $MAX_RETRIES attempts');
        }
        await Future.delayed(const Duration(seconds: 2));
      }
    }


    print('Connected to device: ${device.platformName}');
    setState(() {
      connectionStatus = 'Connected. Initializing ${device.platformName}...';
      connectedDevice = device; 
    });
 
    try {
      var services = await device.discoverServices();
      print('Found ${services.length} services:');
    
      // Log all discovered services
      for (var service in services) {
        print('Service: ${service.uuid}');
      }
      

      // Try to find our target service
      var targetService = services.firstWhere(
        (s) => s.uuid.toString() == SERVICE_UUID.substring(4,8),
        orElse: () {
          print('Target service $SERVICE_UUID not found');
          return services.first; // Return first service as fallback
        },
      );

      print('Using service: ${targetService.uuid}');

      // Get the characteristic for read/write
      var characteristic = targetService.characteristics.firstWhere(
        (c) => c.uuid.toString() == CHARACTERISTIC_UUID.substring(4,8)
      );

      print('Using characteristic ${characteristic.uuid}');

      // Create ObdController instance
      var obdController = ObdController(characteristic);
      print('Found services - initializing odb controller...');
      await obdController.initialize();

      // Send a command and get the response
      OBDCommand.setObdController(obdController);
      var response = await OBDCommand.probe.run();
      // TODO: stop the scan if probe command doesn't return a response

      response = await OBDCommand.powerSwitch.run();
      print('Power Switch: $response');
      response = await OBDCommand.gearPosition.run();
      print('Gear Position: $response');
      response = await OBDCommand.battery12v.run(); 
      print('12V Battery: $response');

      response = await OBDCommand.lbc.run();

      print('SOC: ${response['state_of_charge']}%');
      print('SOH: ${response['hv_battery_health']}%');
      print('Battery Capacity: ${response['hv_battery_Ah']}Ah');
      print('HV Battery Voltage: ${response['hv_battery_voltage']}V');

      int soc = response['state_of_charge'];  
      print('Battery SOC: $soc%');
 
      setState(() {
        connectionStatus = 'Connected';
        batterySOC = soc;
      });
      
    } catch (e) {
      print('Connection error: $e');
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
      print('Disconnecting from device: ${connectedDevice!.platformName}...');
      await connectedDevice!.disconnect();
      connectedDevice = null; // Clear the connected device
      setState(() {
        connectionStatus = 'Disconnected';
        batterySOC = null;
      });
      print('Device disconnected.');
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
                  onTap: isConnecting ? null : () => connectToDevice(device.device), // Disable if connecting
                );
              },
            ),
          ),
          // Log Viewer Section
          Expanded(
            flex: 1,
            child: LogViewer(logs: Logger.instance.logs), // Pass logs to LogViewer
          ),

          // Disconnect Button
          if (connectedDevice != null)
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: ElevatedButton(
                onPressed: disconnectDevice,
                child: const Text('Disconnect'),
              ),
            ),
        ],
      ),
    );
  }
}
