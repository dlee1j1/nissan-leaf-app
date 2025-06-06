// File: test/obd/bluetooth_device_manager_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:mocktail/mocktail.dart';
import 'package:nissan_leaf_app/obd/bluetooth_device_manager.dart';
import 'package:nissan_leaf_app/obd/bluetooth_service_interface.dart';
import 'package:nissan_leaf_app/obd/mock_obd_controller.dart';
import 'package:nissan_leaf_app/obd/obd_command.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
import '../utils/fake_async_utils.dart';

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

class MockBluetoothCharacteristic extends Mock implements BluetoothCharacteristic {
  final StreamController<List<int>> _lastValueController = StreamController<List<int>>.broadcast();

  @override
  Stream<List<int>> get lastValueStream => _lastValueController.stream;

  @override
  Future<bool> setNotifyValue(bool enable, {int timeout = 15, bool forceIndications = false}) {
    return Future.value(true);
  }
}

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
    registerFallbackValue(<int>[]);

    // Set up mock preferences storage
    SharedPreferences.setMockInitialValues({});

    // Initialize test helper and manager
    bluetoothHelper = BluetoothServiceTestHelper();
    manager = BluetoothDeviceManager.instance;
    manager.setBluetoothServiceForTesting(bluetoothHelper.mock);
    manager.setObdControllerFactoryForTesting((params) => MockObdController(params));

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

    // Mock successful write operations
    when(() => mockCharacteristic.write(any(),
        allowLongWrite: false, timeout: 15, withoutResponse: false)).thenAnswer((_) async {});
  });

  group('BluetoothDeviceManager Basic Functionality', () {
    test('scanForDevices turns on Bluetooth if it is off', () {
      runWithFakeAsync((fake) async {
        // Arrange
        bluetoothHelper.setupBluetoothOff();
        bluetoothHelper.setupSuccessfulScan([]);
        when(() => bluetoothHelper.mock.turnOnBluetooth()).thenAnswer((_) async {});

        // Act
        await manager.scanForDevices();
        fake.elapse(Duration(seconds: 10));

        // Assert
        bluetoothHelper.verifyBluetoothTurnedOn();
      });
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

    test('scanForDevices does not throw exception on scan failure', () async {
      // Arrange
      bluetoothHelper.setupBluetoothOn();
      bluetoothHelper.setupFailedScan();

      // Act
      final results = await manager.scanForDevices();

      // Assert
      expect(results.length, 0);
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

    test('autoConnectToObd should exit early when no devices found', () async {
      // Setup empty scan results
      bluetoothHelper.setupBluetoothOn();
      bluetoothHelper.setupSuccessfulScan([]);

      // Act
      final result = await manager.autoConnectToObd();

      // Assert
      expect(result, false);
      verifyNever(() => bluetoothHelper.mock.connectToDevice(any()));
    });
  });

  group('Error Recovery Scenarios', () {
    test('should handle connection timeouts and retry automatically - fake async', () {
      runWithFakeAsync((fake) async {
        // Arrange: Connection times out 3 times
        bluetoothHelper.setupConnectionTimeout(mockDevice);

        // Act: Attempt connection
        final resultFuture = manager.connectToDevice(mockDevice);

        // Advance time to allow for retries (needs to exceed the retry delays)
        fake.elapse(Duration(seconds: 10));

        final result = await resultFuture;

        // Assert: Connection attempt fails
        expect(result, false);

        // Connection should have been attempted the max number of times
        verify(() => bluetoothHelper.mock.connectToDevice(mockDevice)).called(3);

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

    test('should attempt connection to next device if first device fails', () {
      runWithFakeAsync((fake) async {
        // Create two mock devices
        final mockDevice1 = MockBluetoothDevice('device1', 'OBD Failed Device');
        final mockDevice2 = MockBluetoothDevice('device2', 'OBD Working Device');
        final mockResult1 = MockScanResult(mockDevice1);
        final mockResult2 = MockScanResult(mockDevice2);

        // Setup scan to return both devices
        when(() => bluetoothHelper.mock.scanForDevices(
              timeout: any(named: 'timeout'),
              nameFilters: any(named: 'nameFilters'),
            )).thenAnswer((_) async => [mockResult1, mockResult2]);

        // First device fails
        when(() => bluetoothHelper.mock.connectToDevice(mockDevice1))
            .thenAnswer((_) async => false);

        // Second device succeeds
        when(() => bluetoothHelper.mock.connectToDevice(mockDevice2)).thenAnswer((_) async => true);

        // Second device gets proper service discovery
        when(() => bluetoothHelper.mock.discoverServices(mockDevice2))
            .thenAnswer((_) async => [mockService]);

        // Make writes succeed
        when(() => mockCharacteristic.write(any())).thenAnswer((_) async {});

        // Attempt auto-connect
        final resultFuture = manager.autoConnectToObd();

        // Advance time to allow for connection attempts
        fake.elapse(Duration(seconds: 15));

        await resultFuture;

        // Verify that both devices were attempted
        verify(() => bluetoothHelper.mock.connectToDevice(mockDevice1)).called(3);
        verify(() => bluetoothHelper.mock.connectToDevice(mockDevice2)).called(1);
      });
    });

    // Simplified version of the complex error sequence test
    test('should handle error sequences during connection attempts', () {
      // 1. Setup: Bluetooth is off initially
      bluetoothHelper.setupBluetoothOff();
      when(() => bluetoothHelper.mock.turnOnBluetooth()).thenAnswer((_) async {});
      runWithFakeAsync((fake) async {
        // Mock scan response
        when(() => bluetoothHelper.mock.scanForDevices(
              timeout: any(named: 'timeout'),
              nameFilters: any(named: 'nameFilters'),
            )).thenAnswer((_) async => [mockScanResult]);

        // Mock connection failure
        when(() => bluetoothHelper.mock.connectToDevice(mockDevice)).thenAnswer((_) async => false);

        // Attempt auto-connect
        final result = await manager.autoConnectToObd();

        // Should fail
        expect(result, false);

        // Should have turned on Bluetooth
        verify(() => bluetoothHelper.mock.turnOnBluetooth()).called(1);

        // Should have attempted to scan
        verify(() => bluetoothHelper.mock.scanForDevices(
              timeout: any(named: 'timeout'),
              nameFilters: any(named: 'nameFilters'),
            )).called(1);

        // Should have attempted to connect
        verify(() => bluetoothHelper.mock.connectToDevice(mockDevice)).called(3);
      });
    });
  });
  group('OBDDevice Error Handling and Recovery', () {
    setUp(() {
      // Reset any test overrides
      OBDCommand.setTestRunOverride(null);
    });

    test('autoConnectToObd should properly disconnect after failed probe test', () async {
      // Setup successful device connection
      bluetoothHelper.setupBluetoothOn();
      bluetoothHelper.setupSuccessfulScan([mockScanResult]);
      bluetoothHelper.setupSuccessfulConnection(mockDevice);
      bluetoothHelper.setupSuccessfulServiceDiscovery(mockDevice, [mockService]);

      // Make the probe command throw an exception
      OBDCommand.setTestRunOverride((cmd) async {
        if (cmd == OBDCommand.probe) {
          throw Exception('Simulated probe failure');
        }
        return {};
      });

      // Act
      final result = await manager.autoConnectToObd();

      // Assert
      expect(result, false);
      bluetoothHelper.verifyDisconnectionFrom(mockDevice);
    });

    test('autoConnectToObd should disconnect when probe returns empty result', () async {
      bluetoothHelper.setupBluetoothOn();
      bluetoothHelper.setupSuccessfulScan([mockScanResult]);
      bluetoothHelper.setupSuccessfulConnection(mockDevice);
      bluetoothHelper.setupSuccessfulServiceDiscovery(mockDevice, [mockService]);

      // Make the probe command return empty result
      OBDCommand.setTestRunOverride((cmd) async {
        if (cmd == OBDCommand.probe) {
          return {}; // Empty result
        }
        return {'some_data': 'value'};
      });

      // Act
      final result = await manager.autoConnectToObd();

      // Assert
      expect(result, false);
      bluetoothHelper.verifyDisconnectionFrom(mockDevice);
    });

    test('collectCarData should disconnect even if OBD commands fail', () async {
      // Setup successful connection
      bluetoothHelper.setupBluetoothOn();
      bluetoothHelper.setupSuccessfulConnection(mockDevice);
      bluetoothHelper.setupSuccessfulServiceDiscovery(mockDevice, [mockService]);
      bluetoothHelper.setupSuccessfulScan([mockScanResult]);

      // Make the lbc command throw an exception
      OBDCommand.setTestRunOverride((cmd) async {
        if (cmd == OBDCommand.lbc) {
          throw Exception('Simulated LBC command failure');
        }
        return {'soome_data': 'value'};
      });

      // Act
      await manager.collectCarData();

      // Assert - should disconnect despite the error
      bluetoothHelper.verifyDisconnectionFrom(mockDevice);
    });
  });
}
