// test/obd/bluetooth_device_manager_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:mocktail/mocktail.dart';
import 'package:nissan_leaf_app/obd/bluetooth_device_manager.dart';
import 'package:nissan_leaf_app/obd/bluetooth_service_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

    // Initialize manager - permissions will be automatically skipped in test environment
    // since it's neither Android nor iOS
    await manager.initialize();

    // Create mock test data
    mockDevice = MockBluetoothDevice(mockDeviceId, mockDeviceName);
    mockScanResult = MockScanResult(mockDevice);
  });

  group('BluetoothDeviceManager', () {
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
}
