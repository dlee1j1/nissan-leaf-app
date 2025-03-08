// lib/components/dashboard_page.dart (updated version)
import 'package:flutter/material.dart';
import 'package:nissan_leaf_app/background_service.dart';
import 'package:nissan_leaf_app/components/log_viewer.dart';
import 'package:nissan_leaf_app/mqtt_client.dart';
import 'dart:async';
import '../data/reading_model.dart';
import '../data/readings_db.dart';
import '../obd/bluetooth_device_manager.dart';
import '../components/battery_status_widget.dart';
import '../components/service_control_widget.dart';
import '../components/readings_chart_widget.dart';

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> with WidgetsBindingObserver {
  final ReadingsDatabase _db = ReadingsDatabase();
  final BluetoothDeviceManager _deviceManager = BluetoothDeviceManager.instance;

  List<Reading> _readings = [];
  Reading? _currentReading;
  bool _isLoadingCurrent = false;
  bool _isLoadingHistory = false;
  String? _errorMessage;

  // For connection status display
  ConnectionStatus _connectionStatus = ConnectionStatus.disconnected;
  StreamSubscription? _connectionStatusSubscription;

  // MQTT state
  StreamSubscription? _mqttStatusSubscription;
  bool _isMqttConnected = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _setupConnectionListener();
    _setupMqttListener();
    _initializeData();
    // TODO: refresh the page if it's been a while
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // App comes to foreground - start aggressive reconnection
      // TODO: refresh the page if it's been a while
    } else if (state == AppLifecycleState.paused) {
      // App goes to background - stop aggressive reconnection
      _deviceManager.stopForegroundReconnection();
    }
  }

  void _setupConnectionListener() {
    _connectionStatusSubscription = _deviceManager.connectionStatus.listen((status) {
      setState(() {
        _connectionStatus = status;
      });
    });
  }

  void _setupMqttListener() {
    final mqttClient = MqttClient.instance;
    _mqttStatusSubscription = mqttClient.connectionStatus.listen((status) {
      setState(() {
        _isMqttConnected = status == MqttConnectionStatus.connected;
      });
    });

    // Get initial status
    _isMqttConnected = mqttClient.isConnected;
  }

  Future<void> _initializeData() async {
    await _loadHistoricalData();
    await _refreshCurrentReading();
  }

  Future<void> _loadHistoricalData() async {
    try {
      setState(() {
        _isLoadingHistory = true;
        _errorMessage = null;
      });

      // Load last 14 days of readings
      final endDate = DateTime.now();
      final startDate = endDate.subtract(const Duration(days: 14));
      final readings = await _db.getReadingsInRange(startDate, endDate);

      setState(() {
        _readings = readings;
        _isLoadingHistory = false;
      });
    } catch (e) {
      setState(() {
        _isLoadingHistory = false;
        _errorMessage = 'Failed to load historical data: ${e.toString()}';
      });
    }
  }

  Future<void> _refreshCurrentReading() async {
    try {
      setState(() {
        _isLoadingCurrent = true;
        _errorMessage = null;
      });

      // Perform manual collection
      bool success = await BackgroundService.collectManually();
      final latestReading = await _db.getMostRecentReading();

      if (success) {
        // Collection succeeded, reading is the latest from the database
        setState(() {
          _currentReading = latestReading;
          _isLoadingCurrent = false;

          // Add to the readings list and resort
          _readings.add(latestReading!);
          _readings.sort((a, b) => a.timestamp.compareTo(b.timestamp));
        });
        return;
      }

      // If we get here, either collection failed or no reading was found
      setState(() {
        _isLoadingCurrent = false;
        _errorMessage = 'Failed to retrieve battery data';
      });

      // Try to use the existing reading if available
      if (_currentReading == null) {
        setState(() {
          _currentReading = latestReading;
        });

        if (latestReading == null) {
          setState(() {
            _errorMessage = 'No OBD connection or historical data available';
          });
        }
      }
    } catch (e) {
      setState(() {
        _isLoadingCurrent = false;
        _errorMessage = 'Failed to refresh data: ${e.toString()}';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Nissan Leaf Battery Tracker'),
        actions: [
          // Connection status indicator
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0),
            child: Center(
              child: Row(
                children: [
                  Icon(
                    _deviceManager.isConnected || _deviceManager.isInMockMode
                        ? Icons.bluetooth_connected
                        : Icons.bluetooth_disabled,
                    size: 16,
                    color: _deviceManager.isConnected
                        ? Colors.green
                        : _deviceManager.isInMockMode
                            ? Colors.orange
                            : Colors.red,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    _connectionStatus.toString().split('.').last,
                    style: TextStyle(
                      fontSize: 12,
                      color: _deviceManager.isConnected
                          ? Colors.green
                          : _deviceManager.isInMockMode
                              ? Colors.orange
                              : Colors.red,
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Connect button
          IconButton(
            icon: const Icon(Icons.bluetooth),
            tooltip: 'Connect to OBD',
            onPressed: () async {
              if (_deviceManager.isConnected) {
                await _deviceManager.disconnect();
              } else {
                await Navigator.pushNamed(context, '/connection');
                // Refresh after returning from connection page
                _refreshCurrentReading();
              }
            },
          ),
          // Add this PopupMenuButton for settings
          PopupMenuButton<String>(
            icon: const Icon(Icons.settings),
            onSelected: (value) {
              if (value == 'mqtt') {
                Navigator.pushNamed(context, '/mqtt_settings');
              } else if (value == 'settings') {
                // General settings (to be implemented later)
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Settings page coming soon')),
                );
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem<String>(
                value: 'mqtt',
                child: ListTile(
                  leading: Icon(Icons.cloud),
                  title: Text('MQTT Settings'),
                ),
              ),
              const PopupMenuItem<String>(
                value: 'settings',
                child: ListTile(
                  leading: Icon(Icons.settings),
                  title: Text('General Settings'),
                ),
              ),
            ],
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refreshCurrentReading,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Error message if any
              if (_errorMessage != null)
                Card(
                  color: Colors.red[100],
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Row(
                      children: [
                        const Icon(Icons.error, color: Colors.red),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Text(
                            _errorMessage!,
                            style: const TextStyle(color: Colors.red),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

              // Current battery status
              BatteryStatusWidget(
                stateOfCharge: _currentReading?.stateOfCharge ?? 0.0,
                batteryHealth: _currentReading?.batteryHealth ?? 0.0,
                estimatedRange: _currentReading?.estimatedRange,
                lastUpdated: _currentReading?.timestamp,
                isLoading: _isLoadingCurrent,
                onRefresh: _refreshCurrentReading,
              ),

              const SizedBox(height: 16),

              // Background service control
              const ServiceControlWidget(),

              const SizedBox(height: 16),

              // MQTT status
              if (_isMqttConnected)
                Padding(
                  padding: const EdgeInsets.only(top: 8.0),
                  child: Card(
                    color: Colors.green[50],
                    child: Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: Row(
                        children: [
                          Icon(Icons.cloud_done, color: Colors.green),
                          SizedBox(width: 8),
                          Text(
                            'Connected to MQTT',
                            style: TextStyle(color: Colors.green[800]),
                          ),
                          Spacer(),
                          TextButton(
                            onPressed: () {
                              Navigator.pushNamed(context, '/mqtt_settings');
                            },
                            child: Text('Configure'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

              // Log viewer
              SizedBox(
                height: 200,
                child: LogViewer(),
              ),
              const SizedBox(height: 16),
              // Battery charge chart
              ReadingsChartWidget(
                readings: _readings,
                isLoading: _isLoadingHistory,
              ),

              const SizedBox(height: 16),

              // Battery health chart
              ReadingsChartWidget(
                readings: _readings,
                isLoading: _isLoadingHistory,
                title: 'Battery Health History',
                lineColor: Colors.red,
                yAxisTitle: 'Health (%)',
                dataSelector: (reading) => reading.batteryHealth,
              ),

              // Connection status or instructions
              if (!_deviceManager.isConnected && !_deviceManager.isInMockMode)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      children: [
                        const Icon(Icons.bluetooth_disabled, size: 48, color: Colors.grey),
                        const SizedBox(height: 16),
                        Text(
                          'No OBD Connection',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Connect to your vehicle\'s OBD adapter to collect real-time data.',
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 16),
                        ElevatedButton(
                          onPressed: () {
                            Navigator.pushNamed(context, '/connection');
                          },
                          child: const Text('Connect to Vehicle'),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _mqttStatusSubscription?.cancel();
    _connectionStatusSubscription?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _deviceManager.stopForegroundReconnection();
    _db.close();
    super.dispose();
  }
}
