// lib/pages/connection_page.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:nissan_leaf_app/obd/obd_connector.dart';
import 'package:nissan_leaf_app/obd/connection_status.dart';
import 'package:simple_logger/simple_logger.dart';

import '../components/log_viewer.dart';
import '../components/obd_commands_panel.dart';

class ConnectionPage extends StatefulWidget {
  const ConnectionPage({
    super.key,
  });

  @override
  State<ConnectionPage> createState() => _ConnectionPageState();
}

class _ConnectionPageState extends State<ConnectionPage> {
  final _log = SimpleLogger();
  final _manager = OBDConnector();

  List<ScanResult> _devices = [];
  String _connectionStatus = 'Disconnected';
  bool _isScanning = false;

  // Stream subscription for connection status
  StreamSubscription? _connectionStatusSubscription;

  @override
  void initState() {
    super.initState();
    _setupConnectionListener();
    _initializeAndScan();
  }

  void _setupConnectionListener() {
    _connectionStatusSubscription = _manager.connectionStatus.listen((status) {
      setState(() {
        switch (status) {
          case ConnectionStatus.scanning:
            _connectionStatus = 'Scanning...';
            _isScanning = true;
            break;
          case ConnectionStatus.scanComplete:
            _connectionStatus = 'Scan complete';
            _isScanning = false;
            break;
          case ConnectionStatus.connecting:
            _connectionStatus = 'Connecting...';
            break;
          case ConnectionStatus.connected:
            _connectionStatus = 'Connected';
            break;
          case ConnectionStatus.ready:
            _connectionStatus = 'Device ready';
            break;
          case ConnectionStatus.disconnecting:
            _connectionStatus = 'Disconnecting...';
            break;
          case ConnectionStatus.disconnected:
            _connectionStatus = 'Disconnected';
            break;
          case ConnectionStatus.error:
            _connectionStatus = 'Error';
            break;
        }
      });
    });
  }

  Future<void> _initializeAndScan() async {
    await _manager.initialize();

    // Start scanning
    _startScan();
  }

  Future<void> _startScan() async {
    setState(() {
      _isScanning = true;
    });

    try {
      final results = await _manager.scanForDevices();
      setState(() {
        _devices = results;
        _isScanning = false;
      });
    } catch (e) {
      _log.warning('Scan error: $e');
      setState(() {
        _isScanning = false;
      });
    }
  }

  Widget _buildDeviceItem(ScanResult result) {
    return ListTile(
      title:
          Text(result.device.platformName.isEmpty ? 'Unknown Device' : result.device.platformName),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('ID: ${result.device.remoteId}'),
          Text('RSSI: ${result.rssi}'),
          Text('Services: ${result.advertisementData.serviceUuids.join(", ")}'),
          if (result.advertisementData.manufacturerData.isNotEmpty)
            Text('Manufacturer: ${result.advertisementData.manufacturerData}'),
        ],
      ),
      isThreeLine: true,
      onTap: _manager.isConnecting ? null : () => _manager.connectToDevice(result.device),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('OBD Device Connection'),
        actions: [],
      ),
      body: Column(
        children: [
          // Status section
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              children: [
                Text('Status: $_connectionStatus'),
              ],
            ),
          ),

          // Scan controls
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _isScanning ? 'Scanning...' : 'Scan complete',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                ElevatedButton(
                  onPressed: _isScanning ? null : _startScan,
                  child: const Text('Scan for Devices'),
                ),
              ],
            ),
          ),

          // Device list or command panel
          if (_manager.isConnected)
            Expanded(
              child: ObdCommandsPanel(),
            )
          else
            Expanded(
              flex: 2,
              child: ListView.builder(
                itemCount: _devices.length,
                itemBuilder: (context, index) {
                  return _buildDeviceItem(_devices[index]);
                },
              ),
            ),

          // Log viewer
          Expanded(
            flex: 1,
            child: LogViewer(),
          ),

          // Disconnect button
          if (_manager.isConnected)
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ElevatedButton(
                    onPressed: () => _manager.disconnect(),
                    child: const Text('Disconnect'),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _connectionStatusSubscription?.cancel();
    super.dispose();
  }
}
