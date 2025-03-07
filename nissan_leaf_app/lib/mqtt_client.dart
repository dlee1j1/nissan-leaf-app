import 'dart:async';
import 'dart:convert';
import 'package:meta/meta.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:simple_logger/simple_logger.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'mqtt_settings.dart';
import 'app_state.dart';

/// Connection status for the MQTT client
enum MqttConnectionStatus {
  disconnected,
  connecting,
  connected,
  error,
}

/// MQTT Client for Nissan Leaf Battery Tracker
///
/// Handles connection to MQTT broker and publishing of battery data
/// with Home Assistant auto-discovery support
class MqttClient {
  // Static instance for singleton pattern
  static final MqttClient _instance = MqttClient._internal();
  static MqttClient get instance => _instance;
  Connectivity _connectivity = Connectivity();

  // Private constructor for singleton
  MqttClient._internal();

  @visibleForTesting
  void setConnectivityForTest(Connectivity c) {
    _connectivity = c;
  }

  // MQTT client instance
  MqttServerClient? _client;

  // Settings
  MqttSettings? _settings;

  // Connection status
  MqttConnectionStatus _connectionStatus = MqttConnectionStatus.disconnected;
  final _connectionStatusController = StreamController<MqttConnectionStatus>.broadcast();

  // Connection monitoring
  Timer? _keepAliveTimer;

  // Logger
  final _log = SimpleLogger();

  // Getters
  Stream<MqttConnectionStatus> get connectionStatus => _connectionStatusController.stream;
  MqttConnectionStatus get currentStatus => _connectionStatus;
  bool get isConnected => _connectionStatus == MqttConnectionStatus.connected;
  MqttSettings? get settings => _settings;

  /// Initialize the MQTT client with settings
  Future<void> initialize(MqttSettings settings) async {
    _settings = settings;

    // If in mock mode, don't try to actually connect
    if (AppState.instance.mockMode) {
      _log.info('MQTT client initialized in mock mode - no actual connection will be attempted');
      return;
    }

    // If MQTT is enabled, try to connect
    if (settings.enabled && settings.isValid()) {
      connect();
    }
  }

  /// Connect to the MQTT broker
  Future<bool> connect() async {
    // Check if app is in mock mode
    if (AppState.instance.mockMode) {
      _log.info('MOCK MQTT CONNECT - Simulating successful connection to broker');
      _updateStatus(MqttConnectionStatus.connected);
      return true; // Simulate successful connection
    }

    if (_settings == null || !_settings!.isValid()) {
      _log.warning('Cannot connect: Invalid or missing MQTT settings');
      _updateStatus(MqttConnectionStatus.error);
      return false;
    }

    // Check if already connected
    if (_client != null && _client!.connectionStatus?.state == MqttConnectionState.connected) {
      _log.info('Already connected to MQTT broker');
      return true;
    }

    // Check network connectivity
    final connectivityResults = await _connectivity.checkConnectivity();
    if (!connectivityResults.any((result) => result != ConnectivityResult.none)) {
      _log.warning('Cannot connect: No network connectivity');
      _updateStatus(MqttConnectionStatus.error);
      return false;
    }

    _updateStatus(MqttConnectionStatus.connecting);

    try {
      // Create MQTT client
      _client = MqttServerClient(_settings!.broker, _settings!.clientId);

      // Set up client options
      _client!.port = _settings!.port;
      _client!.keepAlivePeriod = 20; // seconds
      _client!.autoReconnect = true;
      _client!.onDisconnected = _onDisconnected;
      _client!.onConnected = _onConnected;
      _client!.onAutoReconnect = _onAutoReconnect;
      _client!.onSubscribed = _onSubscribed;

      // Set secure connection if using port 8883
      if (_settings!.port == 8883) {
        _client!.secure = true;
      }

      // Set connection message
      final connMessage = MqttConnectMessage()
          .withClientIdentifier(_settings!.clientId)
          .withWillTopic(_settings!.getAvailabilityTopic())
          .withWillMessage('offline')
          .withWillQos(MqttQos.atLeastOnce)
          .withWillRetain()
          .startClean();

      _client!.connectionMessage = connMessage;

      // Add credentials if available
      if (await _settings!.hasCredentials()) {
        final password = await _settings!.getPassword();
        _client!.connectionMessage = connMessage.authenticateAs(_settings!.username, password);
      }

      // Connect to broker
      _log.info('Connecting to MQTT broker ${_settings!.broker}:${_settings!.port}...');
      await _client!.connect();

      // Wait for connection or error
      await Future.delayed(const Duration(seconds: 3));

      if (_client!.connectionStatus?.state == MqttConnectionState.connected) {
        _log.info('Connected to MQTT broker');
        _startKeepAliveTimer();

        // Publish online status
        publishAvailability(true);

        // Publish device discovery configuration
        publishDiscoveryConfig();

        return true;
      } else {
        _log.warning('Connection failed: ${_client!.connectionStatus?.returnCode}');
        _updateStatus(MqttConnectionStatus.error);
        return false;
      }
    } catch (e) {
      _log.severe('Exception during MQTT connection: $e');
      _updateStatus(MqttConnectionStatus.error);
      return false;
    }
  }

  /// Disconnect from the MQTT broker
  Future<void> disconnect() async {
    if (_client != null && _client!.connectionStatus?.state == MqttConnectionState.connected) {
      _log.info('Disconnecting from MQTT broker...');

      try {
        // Publish offline status
        publishAvailability(false);

        // Wait for message to be sent
        await Future.delayed(const Duration(milliseconds: 500));

        // Disconnect
        _client!.disconnect();
      } catch (e) {
        _log.warning('Error during disconnect: $e');
      }
    }

    _stopKeepAliveTimer();
    _updateStatus(MqttConnectionStatus.disconnected);
  }

  /// Publish message to a topic
  Future<bool> publish(String topic, String message, {bool retain = false}) async {
    // Check if app is in mock mode
    if (AppState.instance.mockMode) {
      _log.info('MOCK MQTT PUBLISH - Topic: $topic, Message: $message, Retain: $retain');
      return true; // Simulate successful publish
    }

    if (!isConnected || _client == null) {
      _log.warning('Cannot publish: Not connected');
      return false;
    }

    try {
      final builder = MqttClientPayloadBuilder();
      builder.addString(message);

      // Get QoS from settings
      final qos = _getQosLevel();

      _client!.publishMessage(topic, qos, builder.payload!, retain: retain);
      return true;
    } catch (e) {
      _log.warning('Error publishing to $topic: $e');
      return false;
    }
  }

  /// Publish battery data to MQTT
  Future<bool> publishBatteryData({
    required double stateOfCharge,
    required double batteryHealth,
    required double batteryVoltage,
    required double batteryCapacity,
    double? estimatedRange,
    String? sessionId,
  }) async {
    // Check if app is in mock mode
    if (AppState.instance.mockMode) {
      _log.info('MOCK MQTT PUBLISH BATTERY DATA - '
          'SOC: $stateOfCharge%, Health: $batteryHealth%, Voltage: $batteryVoltage V, '
          'Capacity: $batteryCapacity Ah, Range: ${estimatedRange ?? "N/A"} km, '
          'Session: ${sessionId ?? "N/A"}');
      return true; // Simulate successful publish
    }

    if (!isConnected || _settings == null) {
      return false;
    }

    try {
      // Create a data map
      final data = {
        'state_of_charge': stateOfCharge,
        'battery_health': batteryHealth,
        'battery_voltage': batteryVoltage,
        'battery_capacity': batteryCapacity,
        'timestamp': DateTime.now().toIso8601String(),
      };

      // Add optional fields if present
      if (estimatedRange != null) {
        data['estimated_range'] = estimatedRange;
      }

      if (sessionId != null) {
        data['session_id'] = sessionId;
      }

      // Publish individual values to separate topics for Home Assistant
      await publish(_settings!.getStateTopic('soc'), stateOfCharge.toString(), retain: true);
      await publish(_settings!.getStateTopic('health'), batteryHealth.toString(), retain: true);
      await publish(_settings!.getStateTopic('voltage'), batteryVoltage.toString(), retain: true);
      await publish(_settings!.getStateTopic('capacity'), batteryCapacity.toString(), retain: true);

      if (estimatedRange != null) {
        await publish(_settings!.getStateTopic('range'), estimatedRange.toString(), retain: true);
      }

      // Also publish the full data object to a single topic
      final fullDataTopic = '${_settings!.topicPrefix}/${_settings!.clientId}/data';
      await publish(fullDataTopic, jsonEncode(data), retain: true);

      return true;
    } catch (e) {
      _log.warning('Error publishing battery data: $e');
      return false;
    }
  }

  /// Publish Home Assistant discovery configuration
  Future<void> publishDiscoveryConfig() async {
    // Check if in mock mode
    if (AppState.instance.mockMode) {
      _log.info(
          'MOCK MQTT PUBLISH - Home Assistant discovery configuration (skipping details for brevity)');
      return;
    }

    if (!isConnected || _settings == null) {
      return;
    }

    try {
      // Device information (shared across all entities)
      final deviceInfo = {
        'identifiers': [_settings!.clientId],
        'name': 'Nissan Leaf Battery Tracker',
        'model': 'Nissan Leaf',
        'manufacturer': 'Nissan',
        'sw_version': '1.0.0',
      };

      // State of Charge sensor
      final socConfig = {
        'name': 'Nissan Leaf Battery Level',
        'device_class': 'battery',
        'state_class': 'measurement',
        'unit_of_measurement': '%',
        'state_topic': _settings!.getStateTopic('soc'),
        'availability_topic': _settings!.getAvailabilityTopic(),
        'icon': 'mdi:car-electric',
        'unique_id': '${_settings!.clientId}_soc',
        'device': deviceInfo,
      };

      // Battery Health sensor
      final healthConfig = {
        'name': 'Nissan Leaf Battery Health',
        'device_class': 'battery',
        'state_class': 'measurement',
        'unit_of_measurement': '%',
        'state_topic': _settings!.getStateTopic('health'),
        'availability_topic': _settings!.getAvailabilityTopic(),
        'icon': 'mdi:heart-pulse',
        'unique_id': '${_settings!.clientId}_health',
        'device': deviceInfo,
      };

      // Battery Voltage sensor
      final voltageConfig = {
        'name': 'Nissan Leaf Battery Voltage',
        'device_class': 'voltage',
        'state_class': 'measurement',
        'unit_of_measurement': 'V',
        'state_topic': _settings!.getStateTopic('voltage'),
        'availability_topic': _settings!.getAvailabilityTopic(),
        'icon': 'mdi:lightning-bolt',
        'unique_id': '${_settings!.clientId}_voltage',
        'device': deviceInfo,
      };

      // Battery Capacity sensor
      final capacityConfig = {
        'name': 'Nissan Leaf Battery Capacity',
        'state_class': 'measurement',
        'unit_of_measurement': 'Ah',
        'state_topic': _settings!.getStateTopic('capacity'),
        'availability_topic': _settings!.getAvailabilityTopic(),
        'icon': 'mdi:battery',
        'unique_id': '${_settings!.clientId}_capacity',
        'device': deviceInfo,
      };

      // Range sensor
      final rangeConfig = {
        'name': 'Nissan Leaf Range',
        'device_class': 'distance',
        'state_class': 'measurement',
        'unit_of_measurement': 'km',
        'state_topic': _settings!.getStateTopic('range'),
        'availability_topic': _settings!.getAvailabilityTopic(),
        'icon': 'mdi:map-marker-distance',
        'unique_id': '${_settings!.clientId}_range',
        'device': deviceInfo,
      };

      // Publish all configurations
      await publish(_settings!.getDiscoveryTopic('sensor', 'soc'), jsonEncode(socConfig),
          retain: true);
      await publish(_settings!.getDiscoveryTopic('sensor', 'health'), jsonEncode(healthConfig),
          retain: true);
      await publish(_settings!.getDiscoveryTopic('sensor', 'voltage'), jsonEncode(voltageConfig),
          retain: true);
      await publish(_settings!.getDiscoveryTopic('sensor', 'capacity'), jsonEncode(capacityConfig),
          retain: true);
      await publish(_settings!.getDiscoveryTopic('sensor', 'range'), jsonEncode(rangeConfig),
          retain: true);

      _log.info('Published Home Assistant discovery configuration');
    } catch (e) {
      _log.warning('Error publishing discovery config: $e');
    }
  }

  /// Publish availability status
  Future<bool> publishAvailability(bool online) async {
    // Check if in mock mode
    if (AppState.instance.mockMode) {
      _log.info('MOCK MQTT PUBLISH AVAILABILITY - Status: ${online ? "online" : "offline"}');
      return true; // Simulate successful publish
    }

    if (_settings == null) {
      return false;
    }

    try {
      final availabilityTopic = _settings!.getAvailabilityTopic();
      final status = online ? 'online' : 'offline';

      // If disconnected, we use a direct publish method since the client may not be available
      if (!online &&
          (_client == null || _client!.connectionStatus?.state != MqttConnectionState.connected)) {
        // In this case, we can't publish the message
        return false;
      }

      return await publish(availabilityTopic, status, retain: true);
    } catch (e) {
      _log.warning('Error publishing availability: $e');
      return false;
    }
  }

  /// Update connection status and notify listeners
  void _updateStatus(MqttConnectionStatus status) {
    _connectionStatus = status;
    _connectionStatusController.add(status);
  }

  /// Start keep-alive timer to periodically check connection
  void _startKeepAliveTimer() {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = Timer.periodic(const Duration(minutes: 5), (timer) {
      // Check if still connected
      if (_client == null || _client!.connectionStatus?.state != MqttConnectionState.connected) {
        _log.info('Keep-alive check: connection lost, attempting to reconnect...');
        _reconnect();
      } else {
        // Publish availability to ensure the connection is active
        publishAvailability(true);
      }
    });
  }

  /// Stop the keep-alive timer
  void _stopKeepAliveTimer() {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
  }

  /// Attempt to reconnect
  Future<void> _reconnect() async {
    if (_connectionStatus == MqttConnectionStatus.connecting) {
      return; // Already trying to connect
    }

    disconnect();
    await Future.delayed(const Duration(seconds: 2));
    connect();
  }

  /// Get QoS level from settings
  MqttQos _getQosLevel() {
    if (_settings == null) {
      return MqttQos.atMostOnce;
    }

    switch (_settings!.qos) {
      case 1:
        return MqttQos.atLeastOnce;
      case 2:
        return MqttQos.exactlyOnce;
      case 0:
      default:
        return MqttQos.atMostOnce;
    }
  }

  /// Callback for when client connects
  void _onConnected() {
    _log.info('Connected to MQTT broker');
    _updateStatus(MqttConnectionStatus.connected);
  }

  /// Callback for when client disconnects
  void _onDisconnected() {
    _log.info('Disconnected from MQTT broker');
    _updateStatus(MqttConnectionStatus.disconnected);
    _stopKeepAliveTimer();
  }

  /// Callback for when client starts auto-reconnect
  void _onAutoReconnect() {
    _log.info('Auto-reconnecting to MQTT broker');
    _updateStatus(MqttConnectionStatus.connecting);
  }

  /// Callback for when client subscribes to a topic
  void _onSubscribed(String topic) {
    _log.info('Subscribed to topic: $topic');
  }

  /// Dispose of resources
  void dispose() {
    disconnect();
    _stopKeepAliveTimer();
    _connectionStatusController.close();
  }
}
