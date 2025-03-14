// lib/pages/dashboard_page.dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:nissan_leaf_app/components/log_viewer.dart';
import 'package:nissan_leaf_app/mqtt_client.dart';
import 'package:nissan_leaf_app/obd/connection_status.dart';
import 'package:simple_logger/simple_logger.dart';
import 'dart:async';
import '../data/reading_model.dart';
import '../data/readings_db.dart';
import '../obd/bluetooth_device_manager.dart';
import '../components/battery_status_widget.dart';
import '../components/service_control_widget.dart';
import '../components/readings_chart_widget.dart';
import '../data_orchestrator.dart';
import '../components/mock_battery_selector_widget.dart';
import '../background_service_controller.dart';

/// Data orchestration modes
enum AppMode { real, mock, debug }

class DataOrchestratorFactory {
  // Cache of orchestrators
  static final Map<AppMode, DataOrchestrator> _cache = {};

  static DataOrchestrator create(AppMode mode) {
    // Return cached orchestrator if available
    if (_cache.containsKey(mode)) {
      return _cache[mode]!;
    }

    // Create new orchestrator if needed
    DataOrchestrator orchestrator;
    switch (mode) {
      case AppMode.real:
        orchestrator = BackgroundServiceOrchestrator();
        break;
      case AppMode.debug:
        orchestrator = DirectOBDOrchestrator();
        break;
      case AppMode.mock:
        orchestrator = MockDataOrchestrator();
        break;
    }

    _cache[mode] = orchestrator;
    return orchestrator;
  }

  // Call this when app is shutting down
  static void disposeAll() {
    for (var orchestrator in _cache.values) {
      orchestrator.dispose();
    }
    _cache.clear();
  }
}

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> with WidgetsBindingObserver {
  final ReadingsDatabase _db = ReadingsDatabase();
  final BluetoothDeviceManager _deviceManager = BluetoothDeviceManager.instance;
  final _logger = SimpleLogger();

  // Orchestration mode
  AppMode _currentMode = AppMode.real;
  late DataOrchestrator _orchestrator;

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

  // Orchestrator status
  StreamSubscription? _orchestratorStatusSubscription;

  bool isBackgroundServiceSupported() {
    try {
      // Check for Android or iOS
      if (Platform.isAndroid || Platform.isIOS) {
        return true; // Background services are supported
      }
      // Add checks for other platforms as needed
      return false;
    } catch (e) {
      // If `Platform` is not available (e.g., on desktop), assume not supported
      return false;
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // Set initial mode based on platform
    if (!isBackgroundServiceSupported()) {
      _currentMode = AppMode.mock;
    }

    _setupOrchestrator();
    _setupConnectionListener();
    _setupMqttListener();
    _initializeData();
    _setupBackgroundService();
  }

  void _setupBackgroundService() {
    // Configure background service based on mode
    try {
      if (_currentMode == AppMode.real) {
        BackgroundServiceController.startService();
      } else if (_currentMode == AppMode.debug) {
        // Stop background service to avoid conflicts with direct OBD access
        BackgroundServiceController.stopService();
      }
    } on UnsupportedError catch (_) {
      // swallow the error if it's because BackgroundService
      _logger.info("Background Service unsupported on this platform");
    }
  }

  void _setupOrchestrator() {
    // Dispose of existing orchestrator if any
    _orchestratorStatusSubscription?.cancel();

    // Create the appropriate orchestrator
    _orchestrator = DataOrchestratorFactory.create(_currentMode);

    // Listen to status updates
    _orchestratorStatusSubscription = _orchestrator.statusStream.listen((status) {
      setState(() {
        // Update collecting status
        if (status.containsKey('collecting')) {
          _isCollecting = status['collecting'] == true;
        }

        // Handle error state
        if (status.containsKey('error')) {
          _errorMessage = status['error'];
          _isLoadingCurrent = false;
        }

        // Handle successful collection
        if (status.containsKey('collecting') &&
            status['collecting'] == false &&
            !status.containsKey('error')) {
          _loadHistoricalData();
          _updateCurrentReadingFromStatus(status);
        }
      });
    });
  }

  void _setMode(AppMode mode) {
    if (_currentMode == mode) return;

    setState(() {
      _currentMode = mode;
      _setupOrchestrator();
      _setupBackgroundService();

      // Clear any error messages when switching modes
      _errorMessage = null;
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // App comes to foreground - refresh if needed
      if (_currentReading == null ||
          DateTime.now().difference(_currentReading!.timestamp).inMinutes > 10) {
        _loadHistoricalData().then((_) => _refreshCurrentReading());
      }
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

  void _updateCurrentReadingFromStatus(Map<String, dynamic> status) {
    // Try to get latest reading from db first
    _db.getMostRecentReading().then((latestReading) {
      setState(() {
        _currentReading = latestReading;
        _isLoadingCurrent = false;

        // If we got a new reading, add it to the list
        if (latestReading != null &&
            (_readings.isEmpty || latestReading.timestamp.isAfter(_readings.last.timestamp))) {
          _readings.add(latestReading);
          _readings.sort((a, b) => a.timestamp.compareTo(b.timestamp));
        }
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

  bool _isCollecting = false;

  Future<void> _refreshCurrentReading() async {
    if (_isCollecting) {
      return; // Already collecting data
    }

    try {
      setState(() {
        _isLoadingCurrent = true;
        _errorMessage = null;
      });

      // Use the current orchestrator for collection
      await _orchestrator.collectData();

      // Status updates will be handled by the orchestrator status listener
    } catch (e) {
      setState(() {
        _isLoadingCurrent = false;
        _errorMessage = 'Failed to refresh data: ${e.toString()}';
      });
    }
  }

  // Error message card builder
  Widget _buildErrorMessage(String message) {
    return Card(
      color: Colors.red[100],
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Row(
          children: [
            const Icon(Icons.error, color: Colors.red),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(color: Colors.red),
              ),
            ),
          ],
        ),
      ),
    );
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
                    _deviceManager.isConnected
                        ? Icons.bluetooth_connected
                        : Icons.bluetooth_disabled,
                    size: 16,
                    color: _deviceManager.isConnected
                        ? Colors.green
                        : _currentMode == AppMode.mock
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
                          : _currentMode == AppMode.mock
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

          // Mode toggle menu (not shown on web)
          if (!kIsWeb)
            PopupMenuButton<AppMode>(
              icon: const Icon(Icons.mode_edit_outline),
              tooltip: 'Change mode',
              onSelected: _setMode,
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: AppMode.real,
                  child: ListTile(
                    leading: const Icon(Icons.play_arrow),
                    title: const Text('Real Mode'),
                    subtitle: const Text('Background service'),
                    trailing: _currentMode == AppMode.real
                        ? const Icon(Icons.check, color: Colors.green)
                        : null,
                  ),
                ),
                PopupMenuItem(
                  value: AppMode.mock,
                  child: ListTile(
                    leading: const Icon(Icons.content_copy),
                    title: const Text('Mock Mode'),
                    subtitle: const Text('Simulated data'),
                    trailing: _currentMode == AppMode.mock
                        ? const Icon(Icons.check, color: Colors.green)
                        : null,
                  ),
                ),
                PopupMenuItem(
                  value: AppMode.debug,
                  child: ListTile(
                    leading: const Icon(Icons.bug_report),
                    title: const Text('Debug Mode'),
                    subtitle: const Text('Direct OBD access'),
                    trailing: _currentMode == AppMode.debug
                        ? const Icon(Icons.check, color: Colors.green)
                        : null,
                  ),
                ),
              ],
            ),

          // Settings menu
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
              // App mode indicator
              PopupMenuButton<AppMode>(
                onSelected: _setMode,
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: AppMode.real,
                    child: ListTile(
                      leading: const Icon(Icons.play_arrow),
                      title: const Text('Real Mode'),
                      subtitle: const Text('Background service'),
                      trailing: _currentMode == AppMode.real
                          ? const Icon(Icons.check, color: Colors.green)
                          : null,
                    ),
                  ),
                  PopupMenuItem(
                    value: AppMode.mock,
                    child: ListTile(
                      leading: const Icon(Icons.content_copy),
                      title: const Text('Mock Mode'),
                      subtitle: const Text('Simulated data'),
                      trailing: _currentMode == AppMode.mock
                          ? const Icon(Icons.check, color: Colors.green)
                          : null,
                    ),
                  ),
                  PopupMenuItem(
                    value: AppMode.debug,
                    child: ListTile(
                      leading: const Icon(Icons.bug_report),
                      title: const Text('Debug Mode'),
                      subtitle: const Text('Direct OBD access'),
                      trailing: _currentMode == AppMode.debug
                          ? const Icon(Icons.check, color: Colors.green)
                          : null,
                    ),
                  ),
                ],
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 8.0),
                  child: Row(
                    children: [
                      Text(
                        'Current Mode: ',
                        style: Theme.of(context).textTheme.bodyLarge,
                      ),
                      Chip(
                        label: Text(_currentMode.toString().split('.').last,
                            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                        backgroundColor: _currentMode == AppMode.real
                            ? Colors.green
                            : _currentMode == AppMode.mock
                                ? Colors.orange
                                : Colors.blue,
                      ),
                    ],
                  ),
                ),
              ),
              // Error message if any
              if (_errorMessage != null) _buildErrorMessage(_errorMessage!),

              // Mock selector in mock mode or on web
              if (_currentMode == AppMode.mock) const MockBatterySelector(),

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

              // Background service control (only in real mode)
              // TODO: write test that this widget doesn't show in kWeb mode
              if (_currentMode == AppMode.real) const ServiceControlWidget(),

              // Debug mode notice
              if (_currentMode == AppMode.debug)
                Card(
                  color: Colors.blue[50],
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Row(
                      children: [
                        Icon(Icons.bug_report, color: Colors.blue),
                        SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Debug Mode Active',
                                style: TextStyle(fontWeight: FontWeight.bold),
                              ),
                              Text(
                                'Using direct OBD connection. Background service is disabled.',
                                style: TextStyle(fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

              // Log viewer
              SizedBox(
                height: 200,
                child: LogViewer(),
              ),
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
              if (!_deviceManager.isConnected && _currentMode != AppMode.mock)
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
    _orchestratorStatusSubscription?.cancel();
    _orchestrator.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _db.close();
    super.dispose();
  }
}
