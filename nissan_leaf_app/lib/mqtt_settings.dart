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
      return await _secureStorage.getString(_passwordKey);
    } catch (e) {
      _log.warning('Error reading password from secure storage: $e');
      return '';
    }
  }

  /// Set the password in secure storage
  Future<void> setPassword(String password) async {
    try {
      await _secureStorage.setString(_passwordKey, password);
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
