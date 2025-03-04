// lib/components/dashboard_page.dart (updated version)
import 'package:flutter/material.dart';
import 'dart:async';
import '../data/reading_model.dart';
import '../data/readings_db.dart';
import '../obd/obd_command.dart';
import '../obd/bluetooth_device_manager.dart';
import '../components/battery_status_widget.dart';
import '../components/service_control_widget.dart';
import '../components/readings_chart_widget.dart';

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
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

  @override
  void initState() {
    super.initState();
    _setupConnectionListener();
    _initializeData();
  }

  void _setupConnectionListener() {
    _connectionStatusSubscription = _deviceManager.connectionStatus.listen((status) {
      setState(() {
        _connectionStatus = status;
      });
    });
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
    if (!_deviceManager.isConnected && !_deviceManager.isInMockMode) {
      // If we're not connected, try to use the latest reading from the database
      final latestReading = await _db.getMostRecentReading();
      setState(() {
        _currentReading = latestReading;
      });

      // If no reading available, show error
      if (latestReading == null) {
        setState(() {
          _errorMessage = 'No OBD connection or historical data available';
        });
      }
      return;
    }

    try {
      setState(() {
        _isLoadingCurrent = true;
        _errorMessage = null;
      });

      // Collect battery data from the vehicle
      final batteryData = await _deviceManager.runCommand(OBDCommand.lbc);
      final rangeData = await _deviceManager.runCommand(OBDCommand.rangeRemaining);

      if (batteryData.isEmpty) {
        setState(() {
          _isLoadingCurrent = false;
          _errorMessage = 'Failed to retrieve battery data';
        });
        return;
      }

      // Create a reading object from the collected data
      final stateOfCharge = (batteryData['state_of_charge'] as num?)?.toDouble() ?? 0.0;
      final batteryHealth = (batteryData['hv_battery_health'] as num?)?.toDouble() ?? 0.0;
      final batteryVoltage = (batteryData['hv_battery_voltage'] as num?)?.toDouble() ?? 0.0;
      final batteryCapacity = (batteryData['hv_battery_Ah'] as num?)?.toDouble() ?? 0.0;
      final estimatedRange = (rangeData['range_remaining'] as num?)?.toDouble() ?? 0.0;

      final reading = Reading(
        timestamp: DateTime.now(),
        stateOfCharge: stateOfCharge,
        batteryHealth: batteryHealth,
        batteryVoltage: batteryVoltage,
        batteryCapacity: batteryCapacity,
        estimatedRange: estimatedRange,
      );

      // Save the reading to the database
      await _db.insertReading(reading);

      // Update the state
      setState(() {
        _currentReading = reading;
        _isLoadingCurrent = false;

        // Add to the readings list and resort
        _readings.add(reading);
        _readings.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      });
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
                    _deviceManager.isConnected
                        ? 'Connected'
                        : _deviceManager.isInMockMode
                            ? 'Mock Mode'
                            : 'Disconnected',
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
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () {
              // Navigate to settings page (to be implemented)
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Settings page coming soon')),
              );
            },
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
    _connectionStatusSubscription?.cancel();
    _db.close();
    super.dispose();
  }
}
