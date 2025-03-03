import 'package:flutter/material.dart';
import '../data/reading_model.dart';
import '../data/readings_db.dart';
import '../obd/obd_command.dart';
import '../obd/obd_controller.dart';
import 'battery_status_widget.dart';
import 'readings_chart_widget.dart';

class DashboardPage extends StatefulWidget {
  final ObdController? obdController;

  const DashboardPage({super.key, this.obdController});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  final ReadingsDatabase _db = ReadingsDatabase();
  List<Reading> _readings = [];
  Reading? _currentReading;
  bool _isLoadingCurrent = false;
  bool _isLoadingHistory = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _initializeData();
  }

  Future<void> _initializeData() async {
    await _loadHistoricalData();
    if (widget.obdController != null) {
      await _refreshCurrentReading();
    }
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
    if (widget.obdController == null) {
      setState(() {
        _errorMessage = 'OBD controller not available';
      });
      return;
    }

    try {
      setState(() {
        _isLoadingCurrent = true;
        _errorMessage = null;
      });

      // Check if OBD controller is initialized and set it if needed
      OBDCommand.setObdController(widget.obdController!);

      // Collect battery data from the vehicle
      final batteryData = await OBDCommand.lbc.run();
      final rangeData = await OBDCommand.rangeRemaining.run();

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

              // Historical data chart
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
              if (widget.obdController == null)
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
                            // Navigate to connection page (existing functionality)
                            Navigator.pop(context);
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
    _db.close();
    super.dispose();
  }
}

// Extension to allow checking if the OBD controller is set
extension ObdCommandExtension on OBDCommand {
  static bool obdControllerIsSet() {
    try {
      // Try to access a static property or method that would fail if not initialized
      OBDCommand.probe;
      return true;
    } catch (e) {
      if (e.toString().contains('ObdController not initialized')) {
        return false;
      }
      rethrow;
    }
  }
}
