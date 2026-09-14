// test/data_orchestrator_test.dart
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:nissan_leaf_app/data_orchestrator.dart';
import 'package:nissan_leaf_app/obd/bluetooth_device_manager.dart';
import 'package:nissan_leaf_app/data/readings_db.dart';
import 'package:nissan_leaf_app/data/reading_model.dart';
import 'package:nissan_leaf_app/mqtt_client.dart';
import 'package:nissan_leaf_app/obd/obd_command.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nissan_leaf_app/obd/obd_connector.dart';
import './utils/fake_async_utils.dart';

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
    final mockConnector = OBDConnector.forTesting(deviceManager: mockDeviceManager);

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
    test('statusStream emits collection status updates', () {
      runWithFakeAsync((fake) async {
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
          fake.elapse(Duration(milliseconds: 50));

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
    });

    // TEMPORARY (data-pipeline plan, Phase A) - remove alongside
    // lastVerificationData once Phase A verification is done.
    group('lastVerificationData (Phase A, temporary)', () {
      test('picks out speed/odometer/ambient_temp when present in the raw OBD map', () async {
        final carData = {
          'state_of_charge': 85,
          'hv_battery_health': 90,
          'hv_battery_voltage': 360,
          'hv_battery_Ah': 56,
          'range_remaining': 150,
          'speed': 42.0,
          'odometer': 12345,
          'ambient_temp': 21.5,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        };

        when(() => mockDeviceManager.initialize()).thenAnswer((_) async {});
        when(() => mockDeviceManager.isConnected).thenReturn(false);
        when(() => mockDeviceManager.autoConnectToObd()).thenAnswer((_) async => true);
        when(() => mockDeviceManager.collectCarData()).thenAnswer((_) async => carData);
        when(() => mockDatabase.insertReading(any())).thenAnswer((_) async => 1);
        when(() => mockMqttClient.isConnected).thenReturn(false);

        expect(orchestrator.lastVerificationData, isNull);

        await orchestrator.collectData();

        expect(orchestrator.lastVerificationData, {
          'speed': 42.0,
          'odometer': 12345,
          'ambient_temp': 21.5,
        });
      });

      test('is null when none of the verification keys are present', () async {
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

        await orchestrator.collectData();

        expect(orchestrator.lastVerificationData, isNull);
      });
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

  group('BackgroundServiceOrchestrator (#20)', () {
    late MockReadingsDatabase mockDb;
    late List<DataCallback> registeredCallbacks;
    late List<Object> sentCommands;

    BackgroundServiceOrchestrator buildOrchestrator({
      required bool isRunning,
      Future<bool> Function()? startService,
    }) {
      registeredCallbacks = [];
      sentCommands = [];
      return BackgroundServiceOrchestrator(
        db: mockDb,
        isServiceRunning: () async => isRunning,
        startService: startService ?? () async => true,
        sendDataToTask: sentCommands.add,
        addTaskDataCallback: registeredCallbacks.add,
        removeTaskDataCallback: registeredCallbacks.remove,
      );
    }

    setUp(() {
      mockDb = MockReadingsDatabase();
    });

    group('when the service is not running (restart-from-stopped, #20 follow-up)', () {
      test('starts the service and reads the reading back once startupResult succeeds', () async {
        final reading = Reading(
          timestamp: DateTime.fromMillisecondsSinceEpoch(1234),
          stateOfCharge: 80.0,
          batteryHealth: 90.0,
          batteryVoltage: 360.0,
          batteryCapacity: 56.0,
          estimatedRange: 150.0,
        );
        when(() => mockDb.getMostRecentReading()).thenAnswer((_) async => reading);
        final orchestrator = buildOrchestrator(isRunning: false);

        final resultFuture = orchestrator.collectData();
        await Future.delayed(Duration.zero);

        // No refreshNow (or any other command) is sent - onStart()'s own
        // initial cycle is the read, not a message this orchestrator asks for.
        expect(sentCommands, isEmpty);
        expect(registeredCallbacks, hasLength(1));
        registeredCallbacks.single({'type': 'startupResult', 'success': true, 'connected': true});

        final result = await resultFuture;

        expect(result, true);
        expect(orchestrator.isConnected, true);
        expect(registeredCallbacks, isEmpty);
      });

      test('fails without waiting for a message if the service fails to start', () async {
        final orchestrator = buildOrchestrator(isRunning: false, startService: () async => false);

        final result = await orchestrator.collectData();

        expect(result, false);
        expect(orchestrator.lastFailureReason, contains('Failed to start'));
        expect(sentCommands, isEmpty);
        expect(registeredCallbacks, isEmpty);
      });

      test('surfaces a failed startupResult as the failure reason', () async {
        final orchestrator = buildOrchestrator(isRunning: false);

        final resultFuture = orchestrator.collectData();
        await Future.delayed(Duration.zero);
        registeredCallbacks.single(
          {'type': 'startupResult', 'success': false, 'reason': 'No Bluetooth devices in range'},
        );

        final result = await resultFuture;

        expect(result, false);
        expect(orchestrator.lastFailureReason, 'No Bluetooth devices in range');
        verifyNever(() => mockDb.getMostRecentReading());
      });

      test('times out if the newly started service never reports a startupResult', () {
        runWithFakeAsync((fake) async {
          final orchestrator = buildOrchestrator(isRunning: false);

          final resultFuture = orchestrator.collectData();
          fake.elapse(const Duration(seconds: 31));
          final result = await resultFuture;

          expect(result, false);
          expect(orchestrator.lastFailureReason, contains('Timed out'));
          expect(registeredCallbacks, isEmpty);
        });
      });
    });

    test('on a successful refresh, reads the reading back from the database', () async {
      final orchestrator = buildOrchestrator(isRunning: true);
      final reading = Reading(
        timestamp: DateTime.fromMillisecondsSinceEpoch(1234),
        stateOfCharge: 80.0,
        batteryHealth: 90.0,
        batteryVoltage: 360.0,
        batteryCapacity: 56.0,
        estimatedRange: 150.0,
      );
      when(() => mockDb.getMostRecentReading()).thenAnswer((_) async => reading);

      final resultFuture = orchestrator.collectData();
      // sendDataToTask happens synchronously inside collectData(); reply once
      // the callback is registered.
      await Future.delayed(Duration.zero);
      expect(sentCommands, [
        {'command': 'refreshNow'}
      ]);
      expect(registeredCallbacks, hasLength(1));
      registeredCallbacks.single({'type': 'refreshResult', 'success': true});

      final result = await resultFuture;

      expect(result, true);
      expect(registeredCallbacks, isEmpty); // callback unregistered after replying
    });

    test('a busy/stopped/etc reply is surfaced as the failure reason', () async {
      final orchestrator = buildOrchestrator(isRunning: true);

      final resultFuture = orchestrator.collectData();
      await Future.delayed(Duration.zero);
      registeredCallbacks.single({'type': 'refreshResult', 'success': false, 'reason': 'busy'});

      final result = await resultFuture;

      expect(result, false);
      expect(orchestrator.lastFailureReason, 'busy');
      verifyNever(() => mockDb.getMostRecentReading());
    });

    test('times out if the task never replies', () {
      runWithFakeAsync((fake) async {
        final orchestrator = buildOrchestrator(isRunning: true);

        final resultFuture = orchestrator.collectData();
        fake.elapse(const Duration(seconds: 21));
        final result = await resultFuture;

        expect(result, false);
        expect(orchestrator.lastFailureReason, contains('Timed out'));
        expect(registeredCallbacks, isEmpty);
      });
    });

    test('reports an error if no reading is in the database after a successful refresh', () async {
      final orchestrator = buildOrchestrator(isRunning: true);
      when(() => mockDb.getMostRecentReading()).thenAnswer((_) async => null);

      final resultFuture = orchestrator.collectData();
      await Future.delayed(Duration.zero);
      registeredCallbacks.single({'type': 'refreshResult', 'success': true});

      final result = await resultFuture;

      expect(result, false);
      expect(orchestrator.lastFailureReason, contains('No reading available'));
    });

    test('isConnected defaults to false and updates from a refreshNow reply', () async {
      final orchestrator = buildOrchestrator(isRunning: true);
      when(() => mockDb.getMostRecentReading()).thenAnswer((_) async => null);
      expect(orchestrator.isConnected, false);

      final resultFuture = orchestrator.collectData();
      await Future.delayed(Duration.zero);
      registeredCallbacks.single({'type': 'refreshResult', 'success': true, 'connected': true});
      await resultFuture;

      expect(orchestrator.isConnected, true);
    });

    test('refreshStatus asks for status without running a collection', () async {
      final orchestrator = buildOrchestrator(isRunning: true);

      final refreshFuture = orchestrator.refreshStatus();
      await Future.delayed(Duration.zero);
      expect(sentCommands, [
        {'command': 'getStatus'}
      ]);
      registeredCallbacks.single({'type': 'status', 'connected': true});
      await refreshFuture;

      expect(orchestrator.isConnected, true);
      verifyNever(() => mockDb.getMostRecentReading());
    });

    test('refreshStatus reports disconnected without asking when the service is not running', () async {
      final orchestrator = buildOrchestrator(isRunning: false);

      await orchestrator.refreshStatus();

      expect(orchestrator.isConnected, false);
      expect(sentCommands, isEmpty);
    });
  });
}
