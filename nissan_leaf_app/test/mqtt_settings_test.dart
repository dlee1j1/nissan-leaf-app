import 'package:flutter_test/flutter_test.dart';
import 'package:nissan_leaf_app/mqtt_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MqttSettings', () {
    late MqttSettings settings;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      settings = MqttSettings();
    });

    test('has correct default values', () {
      expect(settings.broker, equals(''));
      expect(settings.port, equals(1883));
      expect(settings.username, equals(''));
      expect(settings.clientId, equals('nissan_leaf_battery_tracker'));
      expect(settings.topicPrefix, equals('nissan_leaf'));
      expect(settings.qos, equals(0));
      expect(settings.enabled, equals(false));
    });

    test('isValid returns true only when broker is set', () {
      expect(settings.isValid(), equals(false));

      settings.broker = 'test.mosquitto.org';
      expect(settings.isValid(), equals(true));

      settings.broker = '';
      expect(settings.isValid(), equals(false));
    });

    test('toJson/fromJson correctly serializes and deserializes', () {
      settings.broker = 'test.mosquitto.org';
      settings.port = 8883;
      settings.username = 'testuser';
      settings.clientId = 'test_client';
      settings.topicPrefix = 'test/topic';
      settings.qos = 1;
      settings.enabled = true;

      final json = settings.toJson();
      final deserialized = MqttSettings.fromJson(json);

      expect(deserialized.broker, equals('test.mosquitto.org'));
      expect(deserialized.port, equals(8883));
      expect(deserialized.username, equals('testuser'));
      expect(deserialized.clientId, equals('test_client'));
      expect(deserialized.topicPrefix, equals('test/topic'));
      expect(deserialized.qos, equals(1));
      expect(deserialized.enabled, equals(true));
    });

    test('generates correct Home Assistant topics', () {
      settings.clientId = 'test_client';
      settings.topicPrefix = 'nissan_leaf';

      expect(
        settings.getDiscoveryTopic('sensor', 'battery'),
        equals('homeassistant/sensor/test_client/battery/config'),
      );

      expect(
        settings.getStateTopic('battery'),
        equals('nissan_leaf/test_client/battery/state'),
      );

      expect(
        settings.getAvailabilityTopic(),
        equals('nissan_leaf/test_client/availability'),
      );
    });

    test('should store and retrieve password securely', () async {
      // Define a test password
      const testPassword = 'SecureTestPassword123!';

      // Set the password
      await settings.setPassword(testPassword);

      // Retrieve the password
      final retrievedPassword = await settings.getPassword();

      // Verify it matches what was stored
      expect(retrievedPassword, equals(testPassword));

      // Delete the password
      await settings.deletePassword();

      // Verify it was deleted
      final emptyPassword = await settings.getPassword();
      expect(emptyPassword, equals(''));
    });
  });
}
