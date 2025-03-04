// lib/pages/connection_page.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:simple_logger/simple_logger.dart';

import '../obd/bluetooth_device_manager.dart';
import '../components/log_viewer.dart';
import '../components/obd_commands_panel.dart';

class ConnectionPage extends StatefulWidget {
  final bool forConfiguration;

  const ConnectionPage({
    super.key,
    this.forConfiguration = false,
  });

  @override
  State<ConnectionPage> createState() => _ConnectionPageState();
}

class _ConnectionPageState extends State<ConnectionPage> {
  final _log = SimpleLogger();
  final _manager = BluetoothDeviceManager.instance;

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
          case ConnectionStatus.mockMode:
            _connectionStatus = 'Using mock data';
            break;
        }
      });
    });
  }

  Future<void> _initializeAndScan() async {
    await _manager.initialize();

    // Try to reconnect to saved device if we're in configuration mode
    if (widget.forConfiguration) {
      final reconnected = await _manager.reconnectToSavedDevice();
      if (reconnected) {
        if (mounted) {
          Navigator.pop(context, true); // Return to previous screen
        }
        return;
      }
    }

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

  Future<void> _connectToDevice(BluetoothDevice device) async {
    final connected = await _manager.connectToDevice(device);

    if (connected && widget.forConfiguration) {
      if (mounted) {
        Navigator.pop(context, true); // Return to previous screen
      }
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
      onTap: _manager.isConnecting ? null : () => _connectToDevice(result.device),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('OBD Device Connection'),
        actions: [
          // Mock mode button
          IconButton(
            icon: const Icon(Icons.computer),
            tooltip: 'Enable Mock Mode',
            onPressed: () {
              if (_manager.isInMockMode) {
                _manager.disableMockMode();
              } else {
                _manager.enableMockMode();

                if (widget.forConfiguration) {
                  Navigator.pop(context, true);
                }
              }
            },
          ),
        ],
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
          if (_manager.isConnected || _manager.isInMockMode)
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
