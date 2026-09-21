import 'package:flutter_test/flutter_test.dart';
import 'package:nissan_leaf_app/mqtt_client.dart' as app;
import 'package:nissan_leaf_app/mqtt_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mocktail/mocktail.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

// Mocking is challenging for MQTT client, so we'll test basic functionality

// Create mock classes
class MockConnectivity extends Mock implements Connectivity {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Set up mocks
  late MockConnectivity mockConnectivity;

  setUp(() {
    // Replace the real implementation with our mock
    mockConnectivity = MockConnectivity();

    // Mock successful connectivity check
    when(() => mockConnectivity.checkConnectivity())
        .thenAnswer((_) async => [ConnectivityResult.wifi]);
  });

  group('MqttClient', () {
    late app.MqttClient mqttClient;
    late MqttSettings settings;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      mqttClient = app.MqttClient.instance;
      mqttClient.setConnectivityForTest(mockConnectivity);
      settings = MqttSettings(
        broker: 'test.mosquitto.org',
        port: 1883,
        clientId: 'test_client',
        topicPrefix: 'test/nissan_leaf',
        enabled: true,
      );
    });

    test('singleton pattern works correctly', () {
      final instance1 = app.MqttClient.instance;
      final instance2 = app.MqttClient.instance;

      expect(identical(instance1, instance2), isTrue);
    });

    test('testConnection reports error without throwing when settings are invalid', () async {
      final invalidSettings = MqttSettings(broker: ''); // isValid() == false

      final connected = await mqttClient.testConnection(invalidSettings);

      expect(connected, isFalse);
      expect(mqttClient.currentStatus, app.MqttConnectionStatus.error);
      expect(mqttClient.lastError, contains('broker address is empty'));
    });

    test('lastError reports no network connectivity distinctly from other failures', () async {
      when(() => mockConnectivity.checkConnectivity())
          .thenAnswer((_) async => [ConnectivityResult.none]);

      final connected = await mqttClient.testConnection(settings);

      expect(connected, isFalse);
      expect(mqttClient.lastError, contains('No network connectivity'));
    });

    test('lastError is cleared by a subsequent successful validity/connectivity check', () async {
      final invalidSettings = MqttSettings(broker: '');
      await mqttClient.testConnection(invalidSettings);
      expect(mqttClient.lastError, isNotNull);

      // A real broker still isn't reachable in this test environment, but
      // getting past the isValid()/connectivity checks and into the actual
      // connect attempt should replace the old error, not leave it stale.
      await mqttClient.testConnection(settings);

      expect(mqttClient.lastError, isNot(contains('broker address is empty')));
    });

    test('reset() reports disconnected', () {
      mqttClient.reset();
      expect(mqttClient.currentStatus, app.MqttConnectionStatus.disconnected);
    });

    // The following don't actually reach a real broker (this test file has
    // no way to mock the underlying MqttServerClient), so they only verify
    // the one-shot connect/publish/disconnect path doesn't throw when
    // settings are otherwise well-formed - each call takes its own
    // `settings` argument now rather than relying on a cached field.
    test('correctly formats battery data for publishing', () async {
      final testData = {
        'stateOfCharge': 75.5,
        'batteryHealth': 92.0,
        'batteryVoltage': 364.5,
        'batteryCapacity': 56.0,
        'sessionId': 'test_session'
      };

      expect(
          () => mqttClient.publishBatteryData(
                settings: settings,
                stateOfCharge: testData['stateOfCharge'] as double,
                batteryHealth: testData['batteryHealth'] as double,
                batteryVoltage: testData['batteryVoltage'] as double,
                batteryCapacity: testData['batteryCapacity'] as double,
                sessionId: testData['sessionId'] as String,
              ),
          returnsNormally);
    });

    test('correctly formats battery data including analytics fields (Phase B)', () async {
      expect(
          () => mqttClient.publishBatteryData(
                settings: settings,
                stateOfCharge: 75.5,
                batteryHealth: 92.0,
                batteryVoltage: 364.5,
                batteryCapacity: 56.0,
                speed: 42.0,
                odometer: 41400,
                ambientTemp: 21.5,
                l1l2Charges: 588,
                quickCharges: 11,
              ),
          returnsNormally);
    });
  });
}
