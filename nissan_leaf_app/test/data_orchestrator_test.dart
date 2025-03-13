// test/data_orchestrator_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:nissan_leaf_app/data_orchestrator.dart';
import 'package:nissan_leaf_app/obd/bluetooth_device_manager.dart';
import 'package:nissan_leaf_app/data/readings_db.dart';
import 'package:nissan_leaf_app/data/reading_model.dart';
import 'package:nissan_leaf_app/mqtt_client.dart';
import 'package:nissan_leaf_app/obd/obd_command.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Create mock classes for dependencies
class MockBluetoothDeviceManager extends Mock implements BluetoothDeviceManager {}

class MockReadingsDatabase extends Mock implements ReadingsDatabase {}

class MockMqttClient extends Mock implements MqttClient {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DirectOBDOrchestrator orchestrator;
  late MockBluetoothDeviceManager mockDeviceManager;
  late MockReadingsDatabase mockDatabase;
  late MockMqttClient mockMqttClient;

  // Setup for each test
  setUp(() {
    // Initialize mocks
    mockDeviceManager = MockBluetoothDeviceManager();
    mockDatabase = MockReadingsDatabase();
    mockMqttClient = MockMqttClient();

    // Create a mock OBDConnector that uses the mock device manager
    final mockConnector = OBDConnector.forTesting(
      deviceManager: mockDeviceManager
    );

    // Reset shared preferences
    SharedPreferences.setMockInitialValues({});

    // Set dependencies with mocks
    orchestrator = DirectOBDOrchestrator(
      obdConnector: mockConnector,
      mqttClient: mockMqttClient,
      db: mockDatabase,
    );

    // Register fallback values for matchers
    registerFallbackValue(OBDCommand.lbc);
    registerFallbackValue(Reading(
      timestamp: DateTime.now(),
      stateOfCharge: 0,
      batteryHealth: 0,
      batteryVoltage: 0,
      batteryCapacity: 0,
      estimatedRange: 0,
    ));
    registerFallbackValue(false); // For disconnectAfter parameter
  });

  group('DataOrchestrator', () {
    test('statusStream emits collection status updates', () async {
      // Listen to the status stream
      final statusUpdates = <Map<String, dynamic>>[];
      final subscription = orchestrator.statusStream.listen((status) {
        statusUpdates.add(status);
      });

      try {
        // Set up mock responses
        final carData = {
          'state_of_charge': 85,
          'hv_battery_health': 90,
          'hv_battery_voltage': 360,
          'hv_battery_Ah': 56,
          'range_remaining': 150,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        };

        // Mock device manager behavior - critical fix
        when(() => mockDeviceManager.initialize()).thenAnswer((_) async {});
        when(() => mockDeviceManager.isConnected).thenReturn(false);
        when(() => mockDeviceManager.autoConnectToObd()).thenAnswer((_) async => true);
        when(() => mockDeviceManager.collectCarData()).thenAnswer((_) async => carData);

        // Mock database behavior
        when(() => mockDatabase.insertReading(any())).thenAnswer((_) async => 1);

        // Mock MQTT connection state
        when(() => mockMqttClient.isConnected).thenReturn(false);

        // Call the method under test
        await orchestrator.collectData();

        // Allow time for event processing
        await Future.delayed(const Duration(milliseconds: 50));

        // Verify statusStream emitted events
        expect(statusUpdates, isNotEmpty);
        expect(statusUpdates.first['collecting'], isTrue);
        expect(statusUpdates.last['collecting'], isFalse);
        expect(statusUpdates.last['stateOfCharge'], 85);

        // Verify mock interactions
        verify(() => mockDeviceManager.collectCarData()).called(1);
        verify(() => mockDatabase.insertReading(any())).called(1);
      } finally {
        subscription.cancel();
      }
    });

    test('_getOrCreateSessionId creates new session after 30+ minutes', () async {
      // Setup shared prefs with an old session
      final oldTime = DateTime.now().subtract(const Duration(minutes: 40));
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('current_session_id', 'old_session');
      await prefs.setString('last_collection_time', oldTime.toIso8601String());

      // Set up mock behavior - critical fix
      final carData = {
        'state_of_charge': 85,
        'hv_battery_health': 90,
        'hv_battery_voltage': 360,
        'hv_battery_Ah': 56,
        'range_remaining': 150,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      };

      when(() => mockDeviceManager.initialize()).thenAnswer((_) async {});
      when(() => mockDeviceManager.isConnected).thenReturn(false);
      when(() => mockDeviceManager.autoConnectToObd()).thenAnswer((_) async => true);
      when(() => mockDeviceManager.collectCarData()).thenAnswer((_) async => carData);
      when(() => mockDatabase.insertReading(any())).thenAnswer((_) async => 1);
      when(() => mockMqttClient.isConnected).thenReturn(false);

      // Capture the session ID from the status updates
      String? capturedSessionId;
      final subscription = orchestrator.statusStream.listen((status) {
        if (status['sessionId'] != null) {
          capturedSessionId = status['sessionId'];
        }
      });

      try {
        // Call collectData
        await orchestrator.collectData();

        // Allow time for events to be processed
        await Future.delayed(const Duration(milliseconds: 50));

        // Verify a new session was created (not 'old_session')
        expect(capturedSessionId, isNotNull);
        expect(capturedSessionId, isNot('old_session'));

        // Verify it was stored in shared preferences
        final newSessionId = prefs.getString('current_session_id');
        expect(newSessionId, capturedSessionId);
      } finally {
        subscription.cancel();
      }
    });

    test('_getOrCreateSessionId reuses session if less than 30 minutes', () async {
      // Setup shared prefs with a recent session
      final recentTime = DateTime.now().subtract(const Duration(minutes: 10));
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('current_session_id', 'recent_session');
      await prefs.setString('last_collection_time', recentTime.toIso8601String());

      // Set up mock behavior - critical fix
      final carData = {
        'state_of_charge': 85,
        'hv_battery_health': 90,
        'hv_battery_voltage': 360,
        'hv_battery_Ah': 56,
        'range_remaining': 150,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      };

      when(() => mockDeviceManager.initialize()).thenAnswer((_) async {});
      when(() => mockDeviceManager.isConnected).thenReturn(false);
      when(() => mockDeviceManager.autoConnectToObd()).thenAnswer((_) async => true);
      when(() => mockDeviceManager.collectCarData()).thenAnswer((_) async => carData);
      when(() => mockDatabase.insertReading(any())).thenAnswer((_) async => 1);
      when(() => mockMqttClient.isConnected).thenReturn(false);

      // Capture the session ID
      String? capturedSessionId;
      final subscription = orchestrator.statusStream.listen((status) {
        if (status['sessionId'] != null) {
          capturedSessionId = status['sessionId'];
        }
      });

      try {
        // Call collectData
        await orchestrator.collectData();

        // Allow time for events
        await Future.delayed(const Duration(milliseconds: 50));

        // Verify session was reused
        expect(capturedSessionId, 'recent_session');
      } finally {
        subscription.cancel();
      }
    });

    test('collectData returns false when battery data is empty', () async {
      // Mock empty response
      when(() => mockDeviceManager.initialize()).thenAnswer((_) async {});
      when(() => mockDeviceManager.isConnected).thenReturn(false);
      when(() => mockDeviceManager.autoConnectToObd()).thenAnswer((_) async => true);
      when(() => mockDeviceManager.collectCarData())
          .thenAnswer((_) async => null); // Return null to simulate failure

      // Create a completer that will complete when error is received
      String? errorMessage;
      final subscription = orchestrator.statusStream.listen((status) {
        if (status['error'] != null) {
          errorMessage = status['error'];
        }
      });

      try {
        // Call collectData
        final result = await orchestrator.collectData();

        // Allow time for events
        await Future.delayed(const Duration(milliseconds: 50));

        // Verify result
        expect(result, isFalse);

        // Verify error was reported
        expect(errorMessage, contains('No data collected'));
      } finally {
        subscription.cancel();
      }
    });

    test('collectData publishes to MQTT when connected', () async {
      // Mock response data
      final carData = {
        'state_of_charge': 85,
        'hv_battery_health': 90,
        'hv_battery_voltage': 360,
        'hv_battery_Ah': 56,
        'range_remaining': 150,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      };

      when(() => mockDeviceManager.initialize()).thenAnswer((_) async {});
      when(() => mockDeviceManager.isConnected).thenReturn(false);
      when(() => mockDeviceManager.autoConnectToObd()).thenAnswer((_) async => true);
      when(() => mockDeviceManager.collectCarData()).thenAnswer((_) async => carData);
      when(() => mockDatabase.insertReading(any())).thenAnswer((_) async => 1);

      // Mock MQTT client is connected
      when(() => mockMqttClient.isConnected).thenReturn(true);
      when(() => mockMqttClient.publishBatteryData(
            stateOfCharge: any(named: 'stateOfCharge'),
            batteryHealth: any(named: 'batteryHealth'),
            batteryVoltage: any(named: 'batteryVoltage'),
            batteryCapacity: any(named: 'batteryCapacity'),
            estimatedRange: any(named: 'estimatedRange'),
            sessionId: any(named: 'sessionId'),
          )).thenAnswer((_) async => true);

      // Call collectData
      final result = await orchestrator.collectData();

      // Verify result
      expect(result, isTrue);

      // Verify MQTT publish was called
      verify(() => mockMqttClient.publishBatteryData(
            stateOfCharge: any(named: 'stateOfCharge'),
            batteryHealth: any(named: 'batteryHealth'),
            batteryVoltage: any(named: 'batteryVoltage'),
            batteryCapacity: any(named: 'batteryCapacity'),
            estimatedRange: any(named: 'estimatedRange'),
            sessionId: any(named: 'sessionId'),
          )).called(1);
    });

    test('MQTT publishing errors are caught and do not stop collection', () async {
      // Mock response data
      final carData = {
        'state_of_charge': 85,
        'hv_battery_health': 90,
        'hv_battery_voltage': 360,
        'hv_battery_Ah': 56,
        'range_remaining': 150,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      };

      when(() => mockDeviceManager.initialize()).thenAnswer((_) async {});
      when(() => mockDeviceManager.isConnected).thenReturn(false);
      when(() => mockDeviceManager.autoConnectToObd()).thenAnswer((_) async => true);
      when(() => mockDeviceManager.collectCarData()).thenAnswer((_) async => carData);
      when(() => mockDatabase.insertReading(any())).thenAnswer((_) async => 1);

      // Mock MQTT client is connected but publishing throws an error
      when(() => mockMqttClient.isConnected).thenReturn(true);
      when(() => mockMqttClient.publishBatteryData(
            stateOfCharge: any(named: 'stateOfCharge'),
            batteryHealth: any(named: 'batteryHealth'),
            batteryVoltage: any(named: 'batteryVoltage'),
            batteryCapacity: any(named: 'batteryCapacity'),
            estimatedRange: any(named: 'estimatedRange'),
            sessionId: any(named: 'sessionId'),
          )).thenThrow(Exception('MQTT publish error'));

      // Call collectData - this should not throw
      final result = await orchestrator.collectData();

      // Collection should still succeed despite MQTT error
      expect(result, isTrue);

      // Verify MQTT publish was attempted
      verify(() => mockMqttClient.publishBatteryData(
            stateOfCharge: any(named: 'stateOfCharge'),
            batteryHealth: any(named: 'batteryHealth'),
            batteryVoltage: any(named: 'batteryVoltage'),
            batteryCapacity: any(named: 'batteryCapacity'),
            estimatedRange: any(named: 'estimatedRange'),
            sessionId: any(named: 'sessionId'),
          )).called(1);
    });
  });
}
