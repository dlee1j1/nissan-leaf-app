// lib/pages/dashboard_page.dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:nissan_leaf_app/background_service_controller.dart';
import 'package:nissan_leaf_app/components/log_viewer.dart';
import 'package:nissan_leaf_app/mqtt_client.dart';
import 'package:simple_logger/simple_logger.dart';
import 'dart:async';
import '../data/reading_model.dart';
import '../data/readings_db.dart';
import '../components/battery_status_widget.dart';
import '../components/readings_chart_widget.dart';
import '../data_orchestrator.dart';
import '../components/mock_battery_selector_widget.dart';

/// Data orchestration modes
enum AppMode { real, mock }

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
        // Never construct BackgroundService()/BluetoothDeviceManager here -
        // that's the UI isolate independently driving the same physical BLE
        // connection the real background-task isolate is using, which is
        // exactly the collision #20 traces and fixes. This orchestrator only
        // messages the real service and reads readings.db; see its doc
        // comment.
        orchestrator = BackgroundServiceOrchestrator();
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

  // Orchestration mode
  AppMode _currentMode = AppMode.real;
  late DataOrchestrator _orchestrator;

  List<Reading> _readings = [];
  Reading? _currentReading;
  bool _isLoadingCurrent = false;
  bool _isLoadingHistory = false;
  String? _errorMessage;

  // TEMPORARY (data-pipeline plan, Phase A): raw speed/odometer/ambientTemp
  // from the background service's lastVerificationData, shown only to spot
  // check their OBD decode formulas against the real car. Not persisted,
  // not part of Reading - remove once Phase A verification is done.
  Map<String, dynamic>? _verificationData;

  // Whether the real background service is currently running - not the
  // same thing as whether the dongle is connected. The dashboard never
  // holds its own BluetoothDeviceManager (see #20), so it can't observe
  // either directly; both are asked for via the orchestrator instead.
  bool _serviceRunning = false;
  // The actual dongle link, from the last status/refresh round trip - can
  // be false for long stretches while _serviceRunning is true (a failed
  // cycle disconnects; the service doesn't reconnect until its next
  // attempt, see #17). #20's first pass conflated the two, showing
  // "service alive" as if it meant "connected" - this is that follow-up.
  bool _dongleConnected = false;
  // True when _serviceRunning is true but no Dart isolate backs it up -
  // the exact #22 zombie signature (OS promoted the foreground service,
  // but the Dart TaskHandler never attached). Meaningless when
  // _serviceRunning is false. See BackgroundServiceController
  // .isBackgroundIsolateAlive.
  bool _serviceStalled = false;

  // MQTT state
  StreamSubscription? _mqttStatusSubscription;
  bool _isMqttConnected = false;

  // Orchestrator status
  StreamSubscription? _orchestratorStatusSubscription;

  // Issue #25: the background isolate pushes this proactively on every
  // successful cycle, not just in reply to something the UI asked for -
  // see BackgroundService.execute(). Registered for the widget's whole
  // lifetime (not mode-dependent - mock mode never sends it, so this is a
  // harmless no-op there), unlike _orchestratorStatusSubscription which
  // gets torn down and rebuilt on every mode switch.
  void _onBackgroundServiceData(Object data) {
    if (data is! Map || data['type'] != 'newReading') return;
    // TEMPORARY (data-pipeline plan, Phase A): see DataOrchestrator
    // .lastVerificationData. Not every newReading push carries this.
    final verification = data['verification'];
    if (verification is Map && mounted) {
      setState(() => _verificationData = Map<String, dynamic>.from(verification));
    }
    _refreshCurrentReadingFromDb();
  }

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
    FlutterForegroundTask.addTaskDataCallback(_onBackgroundServiceData);

    // Set initial mode based on platform
    if (!isBackgroundServiceSupported()) {
      _currentMode = AppMode.mock;
    }

    _setupOrchestrator();
    _refreshServiceRunningStatus();
    _setupMqttListener();
    _initializeData();
  }

  /// Refreshes both "is the service running" and "is the dongle actually
  /// connected" - checked on demand rather than via a live stream,
  /// alongside the same moments the dashboard already refreshes (open,
  /// resume, pull-to-refresh, mode switch). See #20: the dashboard has no
  /// BluetoothDeviceManager of its own any more, so both are asked for
  /// rather than observed directly - and they're deliberately kept as two
  /// separate questions, not one, since the service can be alive for a
  /// while with the dongle disconnected (#17).
  Future<void> _refreshServiceRunningStatus() async {
    if (_currentMode != AppMode.real) {
      if (mounted) {
        setState(() {
          _serviceRunning = false;
          _dongleConnected = false;
        });
      }
      return;
    }
    final running = await BackgroundServiceController.isServiceRunning();
    // Only meaningful (and only checked) when running is true - see #22.
    // isBackgroundIsolateAlive is a synchronous, process-wide check, so
    // this costs nothing extra even when it doesn't apply.
    final stalled = running && !BackgroundServiceController.isBackgroundIsolateAlive;
    await _orchestrator.refreshStatus();
    if (mounted) {
      setState(() {
        _serviceRunning = running;
        _serviceStalled = stalled;
        _dongleConnected = _orchestrator.isConnected;
      });
    }
  }

  IconData _statusIcon() {
    if (!_serviceRunning || _serviceStalled) return Icons.bluetooth_disabled;
    return _dongleConnected ? Icons.bluetooth_connected : Icons.bluetooth_searching;
  }

  Color _statusColor() {
    if (_serviceStalled) return Colors.red; // #22: OS says running, Dart isn't there
    if (_dongleConnected) return Colors.green;
    if (_serviceRunning) return Colors.orange; // tracking, just not connected right now
    return _currentMode == AppMode.mock ? Colors.orange : Colors.red;
  }

  String _statusLabel() {
    if (_serviceStalled) return 'Service Stalled';
    if (!_serviceRunning) return 'Service Not Running';
    return _dongleConnected ? 'Connected' : 'Looking for Dongle';
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
          // _loadHistoricalData();
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

      // Clear any error messages when switching modes
      _errorMessage = null;
    });
    _refreshServiceRunningStatus();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshServiceRunningStatus();
      // App comes to foreground - reload the chart from the DB if it's
      // stale, since the background service may have kept collecting while
      // we were away. Deliberately does NOT also force a live collectData()
      // round trip here: merely glancing at the app after being away isn't
      // "please read the dongle now" - that's what pull-to-refresh is for.
      // A stale-triggered live read here used to fire every time someone
      // reopened the app with the car parked, silently re-arming the
      // service's polling loop.
      if (_currentReading == null ||
          DateTime.now().difference(_currentReading!.timestamp).inMinutes > 10) {
        _loadHistoricalData();
      }
    }
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

  final _log = SimpleLogger();
  void _updateCurrentReadingFromStatus(Map<String, dynamic> status) {
    // Try to get latest reading from db first
    Reading? mostRecentReading = Reading.fromMap(status);

    _db.getMostRecentReading().then((latestDbReading) {
      // Determine the most recent reading (outside setState)
      if (latestDbReading != null &&
          (mostRecentReading == null ||
              latestDbReading.timestamp.isAfter(mostRecentReading!.timestamp))) {
        mostRecentReading = latestDbReading;
      }

      // Decide whether to add to readings list (outside setState)
      bool shouldAddToList = mostRecentReading != null &&
          (_readings.isEmpty || mostRecentReading!.timestamp.isAfter(_readings.last.timestamp));

      // Now update the state with the results of our logic
      setState(() {
        _currentReading = mostRecentReading;
        _isLoadingCurrent = false;

        // Add to readings if needed
        if (shouldAddToList) {
          _readings.add(mostRecentReading!);
          _readings.sort((a, b) => a.timestamp.compareTo(b.timestamp));
        }
      }); // setState
    }); // db.getMostRecentReading.then
  }

  /// Handles the #25 background push (see _onBackgroundServiceData): picks
  /// up whatever the service already wrote to the DB on its own timer.
  /// Deliberately DB-only - unlike _refreshCurrentReading, this must never
  /// call _orchestrator.collectData(), or every proactive push would
  /// trigger another live collection round trip right back at the service
  /// that just finished one.
  Future<void> _refreshCurrentReadingFromDb() async {
    final latestDbReading = await _db.getMostRecentReading();
    if (!mounted || latestDbReading == null) return;

    final isNewer = _currentReading == null || latestDbReading.timestamp.isAfter(_currentReading!.timestamp);
    final shouldAddToList =
        _readings.isEmpty || latestDbReading.timestamp.isAfter(_readings.last.timestamp);
    if (!isNewer && !shouldAddToList) return;

    setState(() {
      if (isNewer) _currentReading = latestDbReading;
      if (shouldAddToList) {
        _readings.add(latestDbReading);
        _readings.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      }
    });
  }

  Future<void> _initializeData() async {
    await _loadHistoricalData();
    await _refreshCurrentReading();
  }

  Future<void> _loadHistoricalData() async {
    _log.info("Loading historical data");
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
      // kinda a hack here but
      await _orchestrator.collectData();
      unawaited(_refreshServiceRunningStatus());

      // Status updates will be handled by the orchestrator status listener
    } catch (e) {
      setState(() {
        _isLoadingCurrent = false;
        _errorMessage = 'Failed to refresh data: ${e.toString()}';
      });
    }
  }

  // TEMPORARY (data-pipeline plan, Phase A) - see _verificationData. Not
  // meant to look permanent: plain amber "under test" styling rather than
  // matching the polished cards around it.
  Widget _buildVerificationCard(Map<String, dynamic> data) {
    final speed = data['speed'];
    final odometer = data['odometer'];
    final ambientTemp = data['ambient_temp'];
    final l1l2Charges = data['l1_l2_charges'];
    final quickCharges = data['quick_charges'];
    final rangeRawLength = data['range_remaining_raw_length'];
    final rangeRawBytes = data['range_remaining_raw_bytes'];
    final rangeCandidateMiles = data['range_remaining_candidate_miles'];
    return Card(
      color: Colors.amber[50],
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Verification (temporary - Phase A)',
              style: TextStyle(fontWeight: FontWeight.bold, color: Colors.amber[900]),
            ),
            const SizedBox(height: 4),
            Text('Speed: ${speed ?? '--'} km/h  '
                'Odometer: ${odometer ?? '--'} km  '
                'Ambient: ${ambientTemp ?? '--'}°C'),
            const SizedBox(height: 4),
            Text('L1/L2 charges: ${l1l2Charges ?? '--'}  '
                'Quick charges: ${quickCharges ?? '--'}'),
            if (rangeRawLength != null) ...[
              const SizedBox(height: 4),
              Text('Range response: $rangeRawLength bytes -> $rangeRawBytes'),
            ],
            if (rangeCandidateMiles != null) ...[
              const SizedBox(height: 4),
              Text('Range candidate (unconfirmed): $rangeCandidateMiles mi - compare to dash'),
            ],
          ],
        ),
      ),
    );
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
          // Status indicator - three real states, not a live BLE object's
          // isConnected (the dashboard doesn't hold one any more - #20):
          // not tracking (no service), tracking-but-reconnecting (service
          // alive, dongle currently disconnected - normal between a failed
          // cycle and the next attempt, #17), and connected.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0),
            child: Center(
              child: Row(
                children: [
                  Icon(_statusIcon(), size: 16, color: _statusColor()),
                  const SizedBox(width: 4),
                  Text(
                    _statusLabel(),
                    style: TextStyle(fontSize: 12, color: _statusColor()),
                  ),
                ],
              ),
            ),
          ),

          // Connect button - always opens the pairing page. Connecting and
          // disconnecting the dongle happens there, not from the dashboard.
          IconButton(
            icon: const Icon(Icons.bluetooth),
            tooltip: 'Connect to OBD',
            onPressed: () async {
              await Navigator.pushNamed(context, '/connection');
              // Refresh after returning from the connection page
              _refreshCurrentReading();
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

              // TEMPORARY (data-pipeline plan, Phase A) - remove once
              // verification is done. Updates roughly once per collection
              // cycle (background service interval, default 1 min) - not a
              // live speedometer, just a periodic sanity check.
              if (_verificationData != null) _buildVerificationCard(_verificationData!),

              const SizedBox(height: 16),

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
              if (!_serviceRunning && _currentMode != AppMode.mock)
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
    _orchestratorStatusSubscription?.cancel();
    FlutterForegroundTask.removeTaskDataCallback(_onBackgroundServiceData);
    _orchestrator.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _db.close();
    super.dispose();
  }
}
