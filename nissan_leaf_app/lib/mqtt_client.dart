import 'dart:async';
import 'dart:convert';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:simple_logger/simple_logger.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'mqtt_settings.dart';
import 'app_state.dart';

/// Connection status, reported to the UI. With the one-shot model below,
/// this reflects the outcome of the *last* attempt, not a live socket -
/// [connected] is sticky and stays reported until the next attempt either
/// confirms it again or reports [error]. There is deliberately no ongoing
/// "disconnected because the socket closed" event for a successful publish
/// closing its own connection afterward; that's expected, not a failure.
enum MqttConnectionStatus {
  disconnected,
  connecting,
  connected,
  error,
}

/// MQTT client for the Nissan Leaf Battery Tracker.
///
/// One-shot per call: connect, do the work, disconnect - always, even on
/// failure. There is no persistent session, no keep-alive timer, and no
/// auto-reconnect. This matches how the app actually uses MQTT (a publish
/// once per collection cycle, roughly once a minute while tracking, not a
/// continuous stream) and sidesteps an entire class of bugs a persistent
/// connection needs to handle - reconnect loops, stale cached settings
/// surviving a config change, "is it actually still connected" ambiguity.
/// See the data-pipeline plan's connectivity-model discussion for the
/// reasoning.
///
/// Every method takes [MqttSettings] as a parameter rather than reading a
/// cached field, so every call is guaranteed to use whatever the caller
/// currently has in hand - the exact bug class ("Test Connection" using
/// stale settings from a previous session) this replaces relied on an
/// implicit shared `_settings` field to avoid.
class MqttClient {
  static final MqttClient _instance = MqttClient._internal();
  static MqttClient get instance => _instance;
  Connectivity _connectivity = Connectivity();

  MqttClient._internal();

  void setConnectivityForTest(Connectivity c) {
    _connectivity = c;
  }

  MqttConnectionStatus _connectionStatus = MqttConnectionStatus.disconnected;
  final _connectionStatusController = StreamController<MqttConnectionStatus>.broadcast();

  final _log = SimpleLogger();

  /// Detail behind the most recent [MqttConnectionStatus.error] (or the most
  /// recent publish's partial-failure summary) - the enum alone can't say
  /// *why*, and that "why" is what's missing from every report so far of
  /// "it connects but nothing shows up in HA". Cleared to null at the start
  /// of every connect attempt; set from whichever branch below actually
  /// fails, so it always reflects the most recent attempt, not a stale one.
  String? _lastError;
  String? get lastError => _lastError;

  Stream<MqttConnectionStatus> get connectionStatus => _connectionStatusController.stream;
  MqttConnectionStatus get currentStatus => _connectionStatus;
  bool get isConnected => _connectionStatus == MqttConnectionStatus.connected;

  /// Reset the reported status to disconnected - for when the user turns
  /// MQTT off in Settings. Nothing to actually disconnect (no persistent
  /// session exists between calls), just stop claiming "connected" for a
  /// feature that's now off.
  void reset() {
    _updateStatus(MqttConnectionStatus.disconnected);
  }

  /// Test [settings] with a bare connect-then-disconnect, no data
  /// published. Used by the Settings screen's "Test Connection" - safe to
  /// call regardless of whether `settings.enabled` is set, since testing
  /// is exactly what happens while deciding whether to enable it.
  Future<bool> testConnection(MqttSettings settings) async {
    if (AppState.instance.mockMode) {
      _log.info('MOCK MQTT TEST CONNECTION - simulating success');
      _updateStatus(MqttConnectionStatus.connected);
      return true;
    }

    final client = await _connectOnce(settings);
    if (client == null) return false;
    _disconnectOnce(client);
    return true;
  }

  /// Publish one full battery-data cycle: connect, publish every provided
  /// value to its own state topic plus the combined data topic and the
  /// Home Assistant discovery configs, then disconnect - always, even if
  /// a publish call above failed partway through.
  Future<bool> publishBatteryData({
    required MqttSettings settings,
    required double stateOfCharge,
    required double batteryHealth,
    required double batteryVoltage,
    required double batteryCapacity,
    String? sessionId,
    // Analytics fields (data-pipeline plan, Phase B) - best-effort OBD
    // reads, so any of these may be absent on a given cycle; see
    // BluetoothDeviceManager.collectCarData().
    //
    // No estimatedRange parameter - deliberately not published. See the
    // "REMOVED" note by OBDCommand.extractInt in obd_command.dart: the
    // OBD command that used to feed this returned a frozen value
    // regardless of actual SOC/driving, so there was never anything real
    // to publish here.
    double? speed,
    int? odometer,
    double? ambientTemp,
    int? l1l2Charges,
    int? quickCharges,
  }) async {
    if (AppState.instance.mockMode) {
      _log.info('MOCK MQTT PUBLISH BATTERY DATA - '
          'SOC: $stateOfCharge%, Health: $batteryHealth%, Voltage: $batteryVoltage V, '
          'Capacity: $batteryCapacity Ah, Session: ${sessionId ?? "N/A"}');
      return true;
    }

    final client = await _connectOnce(settings);
    if (client == null) return false;

    try {
      final data = {
        'state_of_charge': stateOfCharge,
        'battery_health': batteryHealth,
        'battery_voltage': batteryVoltage,
        'battery_capacity': batteryCapacity,
        'timestamp': DateTime.now().toIso8601String(),
      };
      if (sessionId != null) data['session_id'] = sessionId;
      if (speed != null) data['speed'] = speed;
      if (odometer != null) data['odometer'] = odometer;
      if (ambientTemp != null) data['ambient_temp'] = ambientTemp;
      if (l1l2Charges != null) data['l1l2_charges'] = l1l2Charges;
      if (quickCharges != null) data['quick_charges'] = quickCharges;

      // Individual publishes are best-effort (one bad topic shouldn't lose
      // the rest), but every failure lands here - collected rather than
      // silently swallowed, so a partial failure is visible instead of
      // looking identical to full success.
      final failedTopics = <String>[];

      _publish(client, settings, settings.getStateTopic('soc'), stateOfCharge.toString(),
          failedTopics);
      _publish(client, settings, settings.getStateTopic('health'), batteryHealth.toString(),
          failedTopics);
      _publish(client, settings, settings.getStateTopic('voltage'), batteryVoltage.toString(),
          failedTopics);
      _publish(client, settings, settings.getStateTopic('capacity'), batteryCapacity.toString(),
          failedTopics);
      if (speed != null) {
        _publish(client, settings, settings.getStateTopic('speed'), speed.toString(), failedTopics);
      }
      if (odometer != null) {
        _publish(
            client, settings, settings.getStateTopic('odometer'), odometer.toString(), failedTopics);
      }
      if (ambientTemp != null) {
        _publish(client, settings, settings.getStateTopic('ambient_temp'), ambientTemp.toString(),
            failedTopics);
      }
      if (l1l2Charges != null) {
        _publish(client, settings, settings.getStateTopic('l1l2_charges'), l1l2Charges.toString(),
            failedTopics);
      }
      if (quickCharges != null) {
        _publish(client, settings, settings.getStateTopic('quick_charges'),
            quickCharges.toString(), failedTopics);
      }

      final fullDataTopic = '${settings.topicPrefix}/${settings.clientId}/data';
      _publish(client, settings, fullDataTopic, jsonEncode(data), failedTopics);

      _publishDiscoveryConfig(client, settings, failedTopics);

      if (failedTopics.isNotEmpty) {
        _lastError = 'Failed to publish ${failedTopics.length} topic(s): ${failedTopics.join(', ')}';
        _log.warning(_lastError!);
        return false;
      }
      return true;
    } catch (e) {
      _lastError = 'Error publishing battery data: $e';
      _log.warning(_lastError!);
      return false;
    } finally {
      _disconnectOnce(client);
    }
  }

  /// Connect [settings] and return the client, or null (with status
  /// already updated to [MqttConnectionStatus.error]) on any failure.
  /// Every caller must disconnect what this returns, including on their
  /// own failure paths - there is no auto-reconnect or lingering session
  /// to clean up later.
  Future<MqttServerClient?> _connectOnce(MqttSettings settings) async {
    _lastError = null;

    if (!settings.isValid()) {
      _lastError = 'Invalid or missing MQTT settings (broker address is empty)';
      _log.warning(_lastError!);
      _updateStatus(MqttConnectionStatus.error);
      return null;
    }

    final connectivityResults = await _connectivity.checkConnectivity();
    if (!connectivityResults.any((result) => result != ConnectivityResult.none)) {
      _lastError = 'No network connectivity';
      _log.warning(_lastError!);
      _updateStatus(MqttConnectionStatus.error);
      return null;
    }

    _updateStatus(MqttConnectionStatus.connecting);

    try {
      // useWebSocket needs a full "wss://host" URI, not a bare hostname
      // (see MqttServerWsConnection.connect in the mqtt_client package) -
      // raw TCP mode wants just the hostname. WebSocket mode is for
      // brokers only reachable that way, e.g. behind a reverse proxy like
      // Cloudflare's standard proxy, which forwards WebSocket upgrades but
      // not raw TCP MQTT on 1883/8883.
      final server = settings.useWebSocket ? 'wss://${settings.broker}' : settings.broker;
      final client = MqttServerClient(server, settings.clientId);
      client.useWebSocket = settings.useWebSocket;
      if (settings.useWebSocket) {
        // Default is ['mqtt', 'mqttv3.1', 'mqttv3.11'] - some brokers/
        // reverse proxies expect exactly one Sec-WebSocket-Protocol value
        // and error (a 502 from Cloudflare in one real case) on more.
        client.websocketProtocols = MqttClientConstants.protocolsSingleDefault;
      }

      client.port = settings.port;
      // No autoReconnect and no keep-alive timer: one-shot, we own the
      // connect/disconnect lifecycle explicitly and never leave a session
      // open long enough to need either.
      client.autoReconnect = false;
      client.keepAlivePeriod = 20;

      // Set secure connection if using port 8883. Irrelevant in WebSocket
      // mode - the package ignores `secure` there and takes TLS-or-not
      // purely from the wss:// scheme above.
      if (!settings.useWebSocket && settings.port == 8883) {
        client.secure = true;
      }

      // MQTT 3.1.1 ("MQTT"/4) explicitly - the package defaults to the
      // old 3.1 handshake ("MQIsdp"/3), which one real broker CONNACKed
      // but then closed within ~60ms of, repeatedly.
      var connMessage = MqttConnectMessage()
          .withProtocolName(MqttClientConstants.mqttV311ProtocolName)
          .withProtocolVersion(MqttClientConstants.mqttV311ProtocolVersion)
          .withClientIdentifier(settings.clientId)
          .startClean();

      if (await settings.hasCredentials()) {
        final password = await settings.getPassword();
        connMessage = connMessage.authenticateAs(settings.username, password);
      }
      client.connectionMessage = connMessage;

      _log.info('Connecting to MQTT broker ${settings.broker}:${settings.port}...');
      await client.connect();

      if (client.connectionStatus?.state == MqttConnectionState.connected) {
        _log.info('Connected to MQTT broker');
        _updateStatus(MqttConnectionStatus.connected);
        return client;
      } else {
        // The broker's own return code (e.g. notAuthorized, badUsernamePassword,
        // identifierRejected) is the difference between "network is fine but
        // the broker rejected us" and every other failure mode - worth
        // capturing verbatim rather than just logging it and losing it.
        _lastError = 'Connection failed: state=${client.connectionStatus?.state}, '
            'returnCode=${client.connectionStatus?.returnCode}';
        _log.warning(_lastError!);
        _updateStatus(MqttConnectionStatus.error);
        return null;
      }
    } catch (e) {
      _lastError = 'Exception during MQTT connection: $e';
      _log.severe(_lastError!);
      _updateStatus(MqttConnectionStatus.error);
      return null;
    }
  }

  /// Disconnect [client]. Deliberately does not touch [_connectionStatus]
  /// on success - the last attempt's outcome (connected/error) stays
  /// reported until the next attempt, rather than flapping to
  /// "disconnected" every cycle for a connection that closing was always
  /// going to do anyway. See the enum doc.
  void _disconnectOnce(MqttServerClient client) {
    try {
      client.disconnect();
    } catch (e) {
      _log.warning('Error during disconnect: $e');
    }
  }

  void _publish(MqttServerClient client, MqttSettings settings, String topic, String message,
      List<String> failedTopics) {
    try {
      final builder = MqttClientPayloadBuilder();
      builder.addString(message);
      client.publishMessage(topic, _getQosLevel(settings), builder.payload!, retain: true);
    } catch (e) {
      _log.warning('Error publishing to $topic: $e');
      failedTopics.add(topic);
    }
  }

  /// How long Home Assistant should wait, after the last update to a
  /// sensor's state topic, before marking it unavailable/stale. There is
  /// no online/offline availability topic any more (that model assumes a
  /// live connection - see the class doc); this is HA's own primitive for
  /// "reports occasionally, not continuously", so it needs no bookkeeping
  /// on our side. Set to 48 hours: the car only reports while driving, so
  /// several days of it sitting parked shouldn't flap every sensor to
  /// unavailable.
  static const int _expireAfterSeconds = 172800;

  void _publishDiscoveryConfig(
      MqttServerClient client, MqttSettings settings, List<String> failedTopics) {
    try {
      final deviceInfo = {
        'identifiers': [settings.clientId],
        'name': 'Nissan Leaf Battery Tracker',
        'model': 'Nissan Leaf',
        'manufacturer': 'Nissan',
        'sw_version': '1.0.0',
      };

      final sensors = <String, Map<String, dynamic>>{
        'soc': {
          'name': 'Nissan Leaf Battery Level',
          'device_class': 'battery',
          'state_class': 'measurement',
          'unit_of_measurement': '%',
          'icon': 'mdi:car-electric',
        },
        'health': {
          'name': 'Nissan Leaf Battery Health',
          'device_class': 'battery',
          'state_class': 'measurement',
          'unit_of_measurement': '%',
          'icon': 'mdi:heart-pulse',
        },
        'voltage': {
          'name': 'Nissan Leaf Battery Voltage',
          'device_class': 'voltage',
          'state_class': 'measurement',
          'unit_of_measurement': 'V',
          'icon': 'mdi:lightning-bolt',
        },
        'capacity': {
          'name': 'Nissan Leaf Battery Capacity',
          'state_class': 'measurement',
          'unit_of_measurement': 'Ah',
          'icon': 'mdi:battery',
        },
        'speed': {
          'name': 'Nissan Leaf Speed',
          'device_class': 'speed',
          'state_class': 'measurement',
          'unit_of_measurement': 'km/h',
          'icon': 'mdi:speedometer',
        },
        'odometer': {
          'name': 'Nissan Leaf Odometer',
          'device_class': 'distance',
          'state_class': 'total_increasing',
          'unit_of_measurement': 'km',
          'icon': 'mdi:counter',
        },
        'ambient_temp': {
          'name': 'Nissan Leaf Ambient Temperature',
          'device_class': 'temperature',
          'state_class': 'measurement',
          'unit_of_measurement': '°C',
          'icon': 'mdi:thermometer',
        },
        'l1l2_charges': {
          'name': 'Nissan Leaf L1/L2 Charges',
          'state_class': 'total_increasing',
          'icon': 'mdi:ev-plug-type1',
        },
        'quick_charges': {
          'name': 'Nissan Leaf Quick Charges',
          'state_class': 'total_increasing',
          'icon': 'mdi:ev-station',
        },
      };

      for (final entry in sensors.entries) {
        final config = {
          ...entry.value,
          'state_topic': settings.getStateTopic(entry.key),
          'expire_after': _expireAfterSeconds,
          'unique_id': '${settings.clientId}_${entry.key}',
          'device': deviceInfo,
        };
        _publish(client, settings, settings.getDiscoveryTopic('sensor', entry.key),
            jsonEncode(config), failedTopics);
      }

      _log.info('Published Home Assistant discovery configuration');
    } catch (e) {
      _log.warning('Error publishing discovery config: $e');
    }
  }

  MqttQos _getQosLevel(MqttSettings settings) {
    switch (settings.qos) {
      case 1:
        return MqttQos.atLeastOnce;
      case 2:
        return MqttQos.exactlyOnce;
      case 0:
      default:
        return MqttQos.atMostOnce;
    }
  }

  void _updateStatus(MqttConnectionStatus status) {
    _connectionStatus = status;
    _connectionStatusController.add(status);
  }

  void dispose() {
    _connectionStatusController.close();
  }
}
