// File: test/obd/bluetooth_device_manager_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:mocktail/mocktail.dart';
import 'package:nissan_leaf_app/obd/bluetooth_device_manager.dart';
import 'package:nissan_leaf_app/obd/bluetooth_service_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
import '../mocks/mock_timer.dart'; // Import the new MockTimer implementation
import 'package:simple_logger/simple_logger.dart';

final _logger = SimpleLogger();

// Mock classes
class MockBluetoothServiceInterface extends Mock implements BluetoothServiceInterface {}

class MockBluetoothDevice extends Mock implements BluetoothDevice {
  final DeviceIdentifier _remoteId;
  final String _name;

  MockBluetoothDevice(String id, this._name) : _remoteId = DeviceIdentifier(id);

  @override
  DeviceIdentifier get remoteId => _remoteId;

  @override
  String get platformName => _name;
}

class MockScanResult extends Mock implements ScanResult {
  final MockBluetoothDevice _device;

  MockScanResult(this._device);

  @override
  BluetoothDevice get device => _device;
}

class MockBluetoothService extends Mock implements BluetoothService {}

class MockBluetoothCharacteristic extends Mock implements BluetoothCharacteristic {}

class MockAdvertisementData extends Mock implements AdvertisementData {
  @override
  final List<Guid> serviceUuids;
  @override
  final Map<int, List<int>> manufacturerData;

  MockAdvertisementData({
    this.serviceUuids = const [],
    this.manufacturerData = const {},
  });
}

// Test helper to make tests more readable
class BluetoothServiceTestHelper {
  final MockBluetoothServiceInterface mock = MockBluetoothServiceInterface();

  // Setup helpers
  void setupBluetoothOn() {
    when(() => mock.isBluetoothOn()).thenAnswer((_) async => true);
  }

  void setupBluetoothOff() {
    when(() => mock.isBluetoothOn()).thenAnswer((_) async => false);
  }

  void setupSuccessfulScan(List<ScanResult> results) {
    when(() => mock.scanForDevices(
          timeout: any(named: 'timeout'),
          nameFilters: any(named: 'nameFilters'),
        )).thenAnswer((_) async => results);
  }

  void setupFailedScan() {
    when(() => mock.scanForDevices(
          timeout: any(named: 'timeout'),
          nameFilters: any(named: 'nameFilters'),
        )).thenThrow(Exception('Scan failed'));
  }

  void setupSuccessfulConnection(BluetoothDevice device) {
    when(() => mock.connectToDevice(device)).thenAnswer((_) async => true);
  }

  void setupFailedConnection(BluetoothDevice device) {
    when(() => mock.connectToDevice(device)).thenAnswer((_) async => false);
  }

  void setupConnectionTimeout(BluetoothDevice device) {
    when(() => mock.connectToDevice(device)).thenThrow(TimeoutException('Connection timed out'));
  }

  void setupSuccessfulServiceDiscovery(BluetoothDevice device, List<BluetoothService> services) {
    when(() => mock.discoverServices(device)).thenAnswer((_) async => services);
  }

  void setupFailedServiceDiscovery(BluetoothDevice device) {
    when(() => mock.discoverServices(device)).thenThrow(Exception('Service discovery failed'));
  }

  // Verification helpers
  void verifyBluetoothTurnedOn() {
    verify(() => mock.turnOnBluetooth()).called(1);
  }

  void verifyScanAttempted() {
    verify(() => mock.scanForDevices(
          timeout: any(named: 'timeout'),
          nameFilters: any(named: 'nameFilters'),
        )).called(1);
  }

  void verifyConnectionAttemptedFor(BluetoothDevice device) {
    verify(() => mock.connectToDevice(device)).called(1);
  }

  void verifyDisconnectionFrom(BluetoothDevice device) {
    verify(() => mock.disconnectDevice(device)).called(1);
  }
}

void main() {
  // Setup for all tests
  late BluetoothServiceTestHelper bluetoothHelper;
  late BluetoothDeviceManager manager;
  late MockTimerController timerController;

  const mockDeviceId = '12:34:56:78:90';
  const mockDeviceName = 'MockOBDDevice';

  // Sample test data
  late MockBluetoothDevice mockDevice;
  late MockScanResult mockScanResult;
  late MockBluetoothService mockService;
  late MockBluetoothCharacteristic mockCharacteristic;

  setUp(() async {
    // Register fallback values for Mocktail (needed for matchers like any())
    registerFallbackValue(MockBluetoothDevice('fallback', 'Fallback'));
    registerFallbackValue(const Duration(seconds: 15));
    registerFallbackValue(<String>['OBDBLE']);

    // Set up mock preferences storage
    SharedPreferences.setMockInitialValues({});

    // Initialize test helper and manager
    bluetoothHelper = BluetoothServiceTestHelper();
    manager = BluetoothDeviceManager.instance;
    manager.setBluetoothServiceForTesting(bluetoothHelper.mock);

    // Initialize timer controller
    timerController = MockTimerController();
    manager.setTimerFactoriesForTesting(
      createTimer: timerController.createTimer,
      createPeriodicTimer: timerController.createPeriodicTimer,
    );

    // Initialize manager - permissions will be automatically skipped in test environment
    // since it's neither Android nor iOS
    await manager.initialize();

    // Create mock test data
    mockDevice = MockBluetoothDevice(mockDeviceId, mockDeviceName);
    mockScanResult = MockScanResult(mockDevice);

    // Setup device with RSSI for sorting in auto-connect
    when(() => mockScanResult.rssi).thenReturn(-65);

    // Setup advertisementData
    final mockAdvData = MockAdvertisementData(
      serviceUuids: [Guid("FFE0")],
      manufacturerData: {
        0: [1, 2, 3]
      },
    );
    when(() => mockScanResult.advertisementData).thenReturn(mockAdvData);

    // Create mock service and characteristic for connection tests
    mockService = MockBluetoothService();
    mockCharacteristic = MockBluetoothCharacteristic();

    // Configure service discovery
    when(() => mockService.uuid).thenReturn(Guid("ffe0"));
    when(() => mockService.characteristics).thenReturn([mockCharacteristic]);
    when(() => mockCharacteristic.uuid).thenReturn(Guid("ffe1"));
  });

  tearDown(() async {
    // Stop any reconnection processes
    manager.stopForegroundReconnection();
    // Reset timer controller
    timerController.resetAll();
  });

  group('BluetoothDeviceManager Basic Functionality', () {
    test('scanForDevices turns on Bluetooth if it is off', () async {
      // Arrange
      bluetoothHelper.setupBluetoothOff();
      bluetoothHelper.setupSuccessfulScan([]);
      when(() => bluetoothHelper.mock.turnOnBluetooth()).thenAnswer((_) async {});

      // Act
      await manager.scanForDevices();

      // Assert
      bluetoothHelper.verifyBluetoothTurnedOn();
    });

    test('scanForDevices returns list of discovered devices', () async {
      // Arrange
      bluetoothHelper.setupBluetoothOn();
      bluetoothHelper.setupSuccessfulScan([mockScanResult]);

      // Act
      final results = await manager.scanForDevices();

      // Assert
      expect(results.length, 1);
      expect(results[0], mockScanResult);
      bluetoothHelper.verifyScanAttempted();
    });

    test('scanForDevices throws exception on scan failure', () async {
      // Arrange
      bluetoothHelper.setupBluetoothOn();
      bluetoothHelper.setupFailedScan();

      // Act & Assert
      expect(() => manager.scanForDevices(), throwsException);
    });

    test('connectToDevice attempts to connect to the device', () async {
      // Arrange
      bluetoothHelper.setupSuccessfulConnection(mockDevice);

      // Mock out service discovery to return an empty list - this will throw an exception
      // which we expect in this test since we're not testing the full connection flow
      when(() => bluetoothHelper.mock.discoverServices(mockDevice)).thenAnswer((_) async => []);

      // Act - this will fail after connection since we're not mocking the full flow,
      // but we only care about verifying the connection is attempted
      try {
        await manager.connectToDevice(mockDevice);
      } catch (e) {
        // Expected exception due to incomplete service mocking
      }

      // Assert
      bluetoothHelper.verifyConnectionAttemptedFor(mockDevice);
    });

    test('enableMockMode sets up mock controller', () async {
      // Act
      manager.enableMockMode();

      // Assert
      expect(manager.isInMockMode, true);
      expect(manager.isConnected, false);
      expect(manager.obdController, isNotNull);
    });

    test('disableMockMode exits mock mode', () async {
      // Arrange
      manager.enableMockMode();
      expect(manager.isInMockMode, true);

      // Act
      manager.disableMockMode();

      // Assert
      expect(manager.isInMockMode, false);
      expect(manager.obdController, isNull);
    });
  });

  group('Aggressive Reconnection Tests', () {
    test('startForegroundReconnection triggers immediate connection attempt', () async {
      bluetoothHelper.setupBluetoothOn();
      // Setup autoConnect mock to track calls
      int scanCallCount = 0;
      when(() => bluetoothHelper.mock.scanForDevices(
            timeout: any(named: 'timeout'),
            nameFilters: any(named: 'nameFilters'),
          )).thenAnswer((_) async {
        scanCallCount++;
        return [];
      });

      // Start foreground reconnection
      manager.startForegroundReconnection();

      // Allow async operations to complete
      await Future.delayed(Duration.zero);

      // Verify scan was attempted
      expect(scanCallCount, 1);
    });

    test('reconnection process succeeds when connection eventually works', () async {
      // Setup a counter to track connection attempts
      int connectionAttempts = 0;
      int tick = 0;

      void logTick(String message) => _logger.info("${tick++} $message");
      // Setup for scan to return our device
      when(() => bluetoothHelper.mock.scanForDevices(
            timeout: any(named: 'timeout'),
            nameFilters: any(named: 'nameFilters'),
          )).thenAnswer((_) async => [mockScanResult]);

      // Setup connection to fail initially then succeed
      when(() => bluetoothHelper.mock.connectToDevice(any())).thenAnswer((_) {
        logTick("Connect: $tick");
        connectionAttempts++;
        // Fail first attempt, succeed on second
        return Future.value(connectionAttempts >= 2);
      });

      // Setup service discovery and other mocks
      when(() => bluetoothHelper.mock.isBluetoothOn()).thenAnswer((_) async => true);
      when(() => bluetoothHelper.mock.discoverServices(any()))
          .thenAnswer((_) async => [mockService]);
      when(() => mockCharacteristic.write(any())).thenAnswer((_) async {});

      // Start with a clean state and collect status updates
      final statusUpdates = <ConnectionStatus>[];
      final statusSubscription = manager.connectionStatus.listen((status) {
        statusUpdates.add(status);
      });

      try {
        // Start the reconnection
        manager.startForegroundReconnection();
        logTick("Started");
        // Allow first attempt to complete (should fail)
        await Future.delayed(Duration.zero);
        logTick("After initial attempt");
        await manager.autoConnectFuture; 
        expect(manager.consecutiveFailures, 1, reason: "Should have failed once");

        // Advance time for second attempt (should succeed)
        timerController.advanceBy(const Duration(seconds: 5));
        logTick("After advanceBy 5");

        await Future.delayed(Duration.zero);

        // Give extra time for all callbacks to complete
        await Future.delayed(const Duration(milliseconds: 200));

        logTick("After Futre.delayed");

        // Verify we attempted connection twice
        expect(connectionAttempts, 2, reason: "Should have attempted connection twice");

        logTick("after connection attemp expect");
        // Check if we saw connecting status at any point
        expect(statusUpdates.contains(ConnectionStatus.connecting), isTrue,
            reason: "Should have seen connecting status");

        logTick("after Should have seen connecting status");
        // Store timer count to check it doesn't change later
        final initialTimerCount = timerController.activeTimerCount;

        // Reset connection tracking for clarity
        connectionAttempts = 0;
        statusUpdates.clear();
        logTick("After connection attempt reset");
        // Advance time again - no new connection attempts should happen
        timerController.advanceBy(const Duration(seconds: 10));
        await Future.delayed(Duration.zero);
        logTick("After pushing 10 seconds");

        // Should have no new connection attempts
        expect(connectionAttempts, 0, reason: "Should not have made more connection attempts");
        expect(statusUpdates.contains(ConnectionStatus.scanning), isFalse,
            reason: "Should not have started scanning again");

        logTick("After checking connection attempts");

        // Timer count should not have increased
        expect(timerController.activeTimerCount, initialTimerCount,
            reason: "Timer count should not have changed");
        logTick("After checking timers");
      } finally {
        statusSubscription.cancel();
      }
    });

    test('stopForegroundReconnection cancels timer', () async {
      bluetoothHelper.setupBluetoothOn();
      // Setup scan to return no devices
      when(() => bluetoothHelper.mock.scanForDevices(
            timeout: any(named: 'timeout'),
            nameFilters: any(named: 'nameFilters'),
          )).thenAnswer((_) async => []);

      // Start reconnection
      manager.startForegroundReconnection();

      // Stop it immediately
      manager.stopForegroundReconnection();

      // Allow initial attempt to complete
      await Future.delayed(Duration.zero);

      // First scan still happens because it was triggered immediately
      bluetoothHelper.verifyScanAttempted();

      // Reset verification
      reset(bluetoothHelper.mock);
      bluetoothHelper.setupBluetoothOn();

      // Advance time - no new scan should happen
      timerController.advanceBy(const Duration(seconds: 5));

      // Allow async operations to complete
      await Future.delayed(Duration.zero);

      // Verify no more scans
      verifyZeroInteractions(bluetoothHelper.mock);
    });
  });

  group('Error Recovery Scenarios', () {
    test('should handle connection timeouts and retry automatically', () async {
      // Arrange: Connection times out 3 times
      bluetoothHelper.setupConnectionTimeout(mockDevice);

      // Act: Attempt connection
      final result = await manager.connectToDevice(mockDevice);

      // Assert: Connection attempt fails
      expect(result, false);

      // Connection should have been attempted the max number of times
      verify(() => bluetoothHelper.mock.connectToDevice(mockDevice)).called(3); // max retries

      // Error state should be set
      expect(manager.lastError, contains('Failed to connect after'));

      // Reset for next test
      reset(bluetoothHelper.mock);

      // Now make connection succeed
      bluetoothHelper.setupSuccessfulConnection(mockDevice);

      // But service discovery fails
      bluetoothHelper.setupFailedServiceDiscovery(mockDevice);

      // Attempt connection again
      final result2 = await manager.connectToDevice(mockDevice);

      // Should still fail but differently
      expect(result2, false);

      // Should still disconnect
      bluetoothHelper.verifyDisconnectionFrom(mockDevice);
    });

    test('should handle failed device initialization after successful connection', () async {
      // Setup successful connection
      bluetoothHelper.setupSuccessfulConnection(mockDevice);

      // But service discovery fails to find target service
      when(() => bluetoothHelper.mock.discoverServices(mockDevice)).thenAnswer((_) async => []);

      // Attempt connection
      final result = await manager.connectToDevice(mockDevice);

      // Connection should fail
      expect(result, false);

      // Should disconnect
      bluetoothHelper.verifyDisconnectionFrom(mockDevice);

      // Should update error status
      expect(manager.lastError, contains('Required OBD service not found'));
    });

    test('should attempt connection to next device if first device fails', () async {
      // Create two mock devices
      final mockDevice1 = MockBluetoothDevice('device1', 'Failed Device');
      final mockDevice2 = MockBluetoothDevice('device2', 'Working Device');
      final mockResult1 = MockScanResult(mockDevice1);
      final mockResult2 = MockScanResult(mockDevice2);

      // Setup scan to return both devices - sort order matters for autoConnectToObd
      when(() => mockResult1.device.platformName).thenReturn('OBD Failed Device');
      when(() => mockResult2.device.platformName).thenReturn('OBD Working Device');

      when(() => bluetoothHelper.mock.scanForDevices(
            timeout: any(named: 'timeout'),
            nameFilters: any(named: 'nameFilters'),
          )).thenAnswer((_) async => [mockResult1, mockResult2]);

      // First device fails
      when(() => bluetoothHelper.mock.connectToDevice(mockDevice1)).thenAnswer((_) async => false);

      // Second device succeeds
      when(() => bluetoothHelper.mock.connectToDevice(mockDevice2)).thenAnswer((_) async => true);

      // Second device gets proper service discovery
      when(() => bluetoothHelper.mock.discoverServices(mockDevice2))
          .thenAnswer((_) async => [mockService]);

      // Make writes succeed to avoid probe command errors
      when(() => mockCharacteristic.write(any())).thenAnswer((_) async {});

      // Attempt auto-connect
      final result = await manager.autoConnectToObd();

      // Note: Expected to be false since we didn't set up the OBD probe response properly
      expect(result, false);

      // Both devices should have been attempted
      verify(() => bluetoothHelper.mock.connectToDevice(mockDevice1)).called(1);
      verify(() => bluetoothHelper.mock.connectToDevice(mockDevice2)).called(1);
    });

    test('should handle complex error sequences during connection attempts', () async {
      // 1. Bluetooth is off initially
      bluetoothHelper.setupBluetoothOff();

      // Start reconnection process
      manager.startForegroundReconnection();

      // Allow initial check to complete
      await Future.delayed(Duration.zero);

      // Verify turnOnBluetooth was called
      verify(() => bluetoothHelper.mock.turnOnBluetooth()).called(1);

      // 2. Now Bluetooth turns on
      when(() => bluetoothHelper.mock.isBluetoothOn()).thenAnswer((_) async => true);

      // 3. But no devices found in first scan
      when(() => bluetoothHelper.mock.scanForDevices(
            timeout: any(named: 'timeout'),
            nameFilters: any(named: 'nameFilters'),
          )).thenAnswer((_) async => []);

      // Advance time to trigger next attempt (using proper Duration)
      timerController.advanceBy(const Duration(seconds: 5));

      // Allow async operations to complete
      await Future.delayed(Duration.zero);

      // Verify scan was attempted
      verify(() => bluetoothHelper.mock.scanForDevices(
            timeout: any(named: 'timeout'),
            nameFilters: any(named: 'nameFilters'),
          )).called(1);

      // 4. Now a device appears in scan
      when(() => bluetoothHelper.mock.scanForDevices(
            timeout: any(named: 'timeout'),
            nameFilters: any(named: 'nameFilters'),
          )).thenAnswer((_) async => [mockScanResult]);

      // 5. But connection fails initially
      when(() => bluetoothHelper.mock.connectToDevice(mockDevice)).thenAnswer((_) async => false);

      // Clear previous verification records
      reset(bluetoothHelper.mock);
      when(() => bluetoothHelper.mock.isBluetoothOn()).thenAnswer((_) async => true);
      when(() => bluetoothHelper.mock.scanForDevices(
            timeout: any(named: 'timeout'),
            nameFilters: any(named: 'nameFilters'),
          )).thenAnswer((_) async => [mockScanResult]);
      when(() => bluetoothHelper.mock.connectToDevice(mockDevice)).thenAnswer((_) async => false);

      // Advance time to trigger next attempt
      timerController.advanceBy(const Duration(seconds: 5));

      // Allow async operations to complete
      await Future.delayed(Duration.zero);

      // Verify connection was attempted
      verify(() => bluetoothHelper.mock.connectToDevice(mockDevice)).called(1);

      // 6. Now connection succeeds
      reset(bluetoothHelper.mock);
      when(() => bluetoothHelper.mock.isBluetoothOn()).thenAnswer((_) async => true);
      when(() => bluetoothHelper.mock.scanForDevices(
            timeout: any(named: 'timeout'),
            nameFilters: any(named: 'nameFilters'),
          )).thenAnswer((_) async => [mockScanResult]);
      when(() => bluetoothHelper.mock.connectToDevice(mockDevice)).thenAnswer((_) async => true);

      // Setup successful service discovery
      when(() => bluetoothHelper.mock.discoverServices(mockDevice))
          .thenAnswer((_) async => [mockService]);

      // Make writes succeed to avoid probe command errors
      when(() => mockCharacteristic.write(any())).thenAnswer((_) async {});

      // Advance time again
      timerController.advanceBy(const Duration(seconds: 5));

      // Allow async operations to complete
      await Future.delayed(Duration.zero);

      // Verify connection was attempted
      verify(() => bluetoothHelper.mock.connectToDevice(mockDevice)).called(1);
    });

    test('should use prime number intervals to avoid timer conflicts', () async {
      // Setup scan to return no devices initially
      when(() => bluetoothHelper.mock.scanForDevices(
            timeout: any(named: 'timeout'),
            nameFilters: any(named: 'nameFilters'),
          )).thenAnswer((_) async => []);

      // Start the reconnection with 5 second interval (not in test, just in production code)
      manager.startForegroundReconnection();

      // Allow initial attempt to complete
      await Future.delayed(Duration.zero);

      // Verify first scan happened
      verify(() => bluetoothHelper.mock.scanForDevices(
            timeout: any(named: 'timeout'),
            nameFilters: any(named: 'nameFilters'),
          )).called(1);

      // Reset verification
      reset(bluetoothHelper.mock);

      // Now advance by various prime number durations to verify timer behavior
      // Advance by 3 seconds
      timerController.advanceBy(const Duration(seconds: 3));
      await Future.delayed(Duration.zero);
      verifyNever(() => bluetoothHelper.mock.scanForDevices(
            timeout: any(named: 'timeout'),
            nameFilters: any(named: 'nameFilters'),
          ));

      // Advance by 2 more seconds to hit the 5 second mark
      timerController.advanceBy(const Duration(seconds: 2));
      await Future.delayed(Duration.zero);
      verify(() => bluetoothHelper.mock.scanForDevices(
            timeout: any(named: 'timeout'),
            nameFilters: any(named: 'nameFilters'),
          )).called(1);

      // Reset verification
      reset(bluetoothHelper.mock);

      // Now advance by a large prime number
      timerController.advanceBy(const Duration(seconds: 11));
      await Future.delayed(Duration.zero);
      // Should have triggered twice (at 5s and 10s after the previous point)
      verify(() => bluetoothHelper.mock.scanForDevices(
            timeout: any(named: 'timeout'),
            nameFilters: any(named: 'nameFilters'),
          )).called(2);
    });
  });
}
