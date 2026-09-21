import 'package:simple_logger/simple_logger.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:encrypted_shared_preferences/encrypted_shared_preferences.dart';

/// Model class for MQTT connection settings
///
/// Stores and validates MQTT connection parameters and securely
/// manages credentials using flutter_secure_storage
class MqttSettings {
  // Default values
  static const int defaultPort = 1883;
  static const int defaultQos = 0;

  // Settings storage keys
  static const String _brokerKey = 'mqtt_broker';
  static const String _portKey = 'mqtt_port';
  static const String _usernameKey = 'mqtt_username';
  static const String _clientIdKey = 'mqtt_client_id';
  static const String _topicPrefixKey = 'mqtt_topic_prefix';
  static const String _qosKey = 'mqtt_qos';
  static const String _enabledKey = 'mqtt_enabled';
  static const String _useWebSocketKey = 'mqtt_use_websocket';

  // Secure storage key for password
  static const String _passwordKey = 'mqtt_password';

  // Settings properties
  String broker;
  int port;
  String username;
  String clientId;
  String topicPrefix;
  int qos;
  bool enabled;
  // Connect via secure WebSocket (wss://broker) instead of raw TCP. Needed
  // for brokers only reachable behind a reverse proxy that terminates TLS
  // and speaks HTTP(S)/WebSocket upgrades - e.g. Cloudflare's standard
  // proxy, which forwards WebSocket connections fine but not raw TCP MQTT
  // on 1883/8883. Port still applies (443 for a typical wss:// setup).
  bool useWebSocket;

  // Secure storage instance
  final EncryptedSharedPreferences _secureStorage = EncryptedSharedPreferences();
  final _log = SimpleLogger();

  MqttSettings({
    this.broker = '',
    this.port = defaultPort,
    this.username = '',
    this.clientId = 'nissan_leaf_battery_tracker',
    this.topicPrefix = 'nissan_leaf',
    this.qos = defaultQos,
    this.enabled = false,
    this.useWebSocket = false,
  });

  /// Validate settings
  ///
  /// Returns true if the settings are valid, false otherwise.
  /// A valid configuration requires at minimum a broker address.
  bool isValid() {
    return broker.isNotEmpty;
  }

  /// Check if credentials are set
  ///
  /// Returns true if both username and password are set
  Future<bool> hasCredentials() async {
    final password = await getPassword();
    return username.isNotEmpty && password.isNotEmpty;
  }

  /// Get the password from secure storage
  ///
  /// Returns an empty string if no password is set
  Future<String> getPassword() async {
    try {
      final password = await _secureStorage.getString(_passwordKey);
      // TEMPORARY diagnostic - length only, never the password itself.
      // Investigating a report that the saved password "gets forgotten".
      _log.info('getPassword: retrieved ${password.length} characters');
      return password;
    } catch (e) {
      _log.warning('Error reading password from secure storage: $e');
      return '';
    }
  }

  /// Set the password in secure storage
  Future<void> setPassword(String password) async {
    try {
      await _secureStorage.setString(_passwordKey, password);
      // TEMPORARY diagnostic - see getPassword().
      _log.info('setPassword: stored ${password.length} characters');
    } catch (e) {
      _log.severe('Error writing password to secure storage: $e');
      rethrow;
    }
  }

  /// Delete the password from secure storage
  Future<void> deletePassword() async {
    try {
      await _secureStorage.remove(_passwordKey);
    } catch (e) {
      _log.warning('Error deleting password from secure storage: $e');
    }
  }

  /// Persist just the enabled flag, independent of the rest of the form.
  ///
  /// The Settings screen's on/off switch is meant to take effect
  /// immediately - unlike the switch, the other fields need "Save Settings"
  /// because there's text mid-edit to validate first, but there's nothing
  /// to validate here. Writing only this one key (not the full
  /// [saveSettings]) matters: this object's other fields reflect whatever
  /// was loaded at screen-open time, and calling the full save here would
  /// silently overwrite a broker/port/etc. edit the user has typed but not
  /// yet saved. Without this, flipping the switch only changes what the
  /// screen displays - the real background collection cycle, which reloads
  /// settings from storage on every cycle, never sees it and just keeps
  /// skipping MQTT until "Save Settings" is also pressed.
  Future<void> setEnabledImmediately(bool value) async {
    enabled = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_enabledKey, value);
      _log.info('MQTT enabled flag saved: $value');
    } catch (e) {
      _log.severe('Error saving MQTT enabled flag: $e');
      rethrow;
    }
  }

  /// Save settings to SharedPreferences
  Future<void> saveSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      await prefs.setString(_brokerKey, broker);
      await prefs.setInt(_portKey, port);
      await prefs.setString(_usernameKey, username);
      await prefs.setString(_clientIdKey, clientId);
      await prefs.setString(_topicPrefixKey, topicPrefix);
      await prefs.setInt(_qosKey, qos);
      await prefs.setBool(_enabledKey, enabled);
      await prefs.setBool(_useWebSocketKey, useWebSocket);

      _log.info('MQTT settings saved');
    } catch (e) {
      _log.severe('Error saving MQTT settings: $e');
      rethrow;
    }
  }

  /// Load settings from SharedPreferences
  Future<void> loadSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      broker = prefs.getString(_brokerKey) ?? '';
      port = prefs.getInt(_portKey) ?? defaultPort;
      username = prefs.getString(_usernameKey) ?? '';
      clientId = prefs.getString(_clientIdKey) ?? 'nissan_leaf_battery_tracker';
      topicPrefix = prefs.getString(_topicPrefixKey) ?? 'nissan_leaf';
      qos = prefs.getInt(_qosKey) ?? defaultQos;
      enabled = prefs.getBool(_enabledKey) ?? false;
      useWebSocket = prefs.getBool(_useWebSocketKey) ?? false;

      _log.info('MQTT settings loaded');
    } catch (e) {
      _log.warning('Error loading MQTT settings: $e');
      // Use defaults if settings can't be loaded
    }
  }

  /// Convert settings to JSON for storage or serialization
  Map<String, dynamic> toJson() {
    return {
      'broker': broker,
      'port': port,
      'username': username,
      'clientId': clientId,
      'topicPrefix': topicPrefix,
      'qos': qos,
      'enabled': enabled,
      'useWebSocket': useWebSocket,
    };
  }

  /// Create settings from JSON
  factory MqttSettings.fromJson(Map<String, dynamic> json) {
    return MqttSettings(
      broker: json['broker'] ?? '',
      port: json['port'] ?? defaultPort,
      username: json['username'] ?? '',
      clientId: json['clientId'] ?? 'nissan_leaf_battery_tracker',
      topicPrefix: json['topicPrefix'] ?? 'nissan_leaf',
      qos: json['qos'] ?? defaultQos,
      enabled: json['enabled'] ?? false,
      useWebSocket: json['useWebSocket'] ?? false,
    );
  }

  /// Build Home Assistant discovery topic for a specific entity
  String getDiscoveryTopic(String entityType, String entityId) {
    return 'homeassistant/$entityType/$clientId/$entityId/config';
  }

  /// Build state topic for a specific entity
  String getStateTopic(String entityId) {
    return '$topicPrefix/$clientId/$entityId/state';
  }

  /// Build availability topic
  String getAvailabilityTopic() {
    return '$topicPrefix/$clientId/availability';
  }
}
