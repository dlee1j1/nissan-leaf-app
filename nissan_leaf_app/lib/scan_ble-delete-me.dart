import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

void main() {
  runApp(const NissanLeafApp());
}

class NissanLeafApp extends StatelessWidget {
  const NissanLeafApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nissan Leaf OBD',
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      home: const BleScanPage(),
    );
  }
}

class BleScanPage extends StatefulWidget {
  const BleScanPage({super.key});

  @override
  State<BleScanPage> createState() => _BleScanPageState();
}

class _BleScanPageState extends State<BleScanPage> {
  List<ScanResult> devices = [];

  final String OBD_SERVICE_UUID = "FFF0";
  final String OBD_CHARACTERISTIC_UUID = "FFF1";

  void startScan() async {
    try {
      print('Starting scan...');
      setState(() {
        devices.clear();
        print('Cleared existing devices');
      });
      
      print('Beginning discovery...');
      FlutterBluePlus.scanResults.listen(
        (results) {
          setState(() {
            devices = results;
            for (var result in results) {
              // Debug logging
              print('Device Found: ${result.device.name}');
              print('  Address: ${result.device.id}');
              print('  RSSI: ${result.rssi}');
              print('  Services: ${result.advertisementData.serviceUuids}');
              print('  Manufacturer Data: ${result.advertisementData.manufacturerData}');
              print('  Service Data: ${result.advertisementData.serviceData}');
              print('  Connectable: ${result.advertisementData.connectable}');
              print('----------------------------------------');
            }
          });
        },
        onError: (error) => print('Discovery error: $error'),
      );
      
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 4));
    } catch (e) {
      print('Error scanning: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Nissan Leaf OBD Scanner'),
      ),
      body: Column(
        children: [
          ElevatedButton(
            onPressed: startScan,
            child: const Text('Scan for OBD Devices'),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: devices.length,
              itemBuilder: (context, index) {
                final device = devices[index].device;
                final adData = devices[index].advertisementData;
                return ListTile(
                  title: Text(device.name.isEmpty ? 'Unknown Device' : device.name),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('ID: ${device.id.id}'),
                      Text('Services: ${adData.serviceUuids}'),
                      Text('Manufacturer: ${adData.manufacturerData}'),
                      Text('TX Power Level: ${adData.txPowerLevel}'),
                    ],
                  ),
                  onTap: () {
                    print('Selected device: ${device.name}');
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}