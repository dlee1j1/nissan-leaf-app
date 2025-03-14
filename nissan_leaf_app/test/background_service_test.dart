// test/background_service_test.dart
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:nissan_leaf_app/background_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mocktail/mocktail.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:location/location.dart' as loc;
import 'package:nissan_leaf_app/data_orchestrator.dart';
import 'package:nissan_leaf_app/background_service_controller.dart';

// Mock classes
class MockLocation extends Mock implements loc.Location {
  final StreamController<loc.LocationData> _locationController =
      StreamController<loc.LocationData>.broadcast();

  @override
  Stream<loc.LocationData> get onLocationChanged => _locationController.stream;

  // Helper to simulate location changes
  void simulateLocationChange(MockLocationData locationData) {
    _locationController.add(locationData);
  }

  void dispose() {
    _locationController.close();
  }
}

class MockLocationData implements loc.LocationData {
  @override
  final double latitude;
  @override
  final double longitude;

  // Implement all the required fields from LocationData
  @override
  final double accuracy = 10.0;
  @override
  final double altitude = 0.0;
  @override
  final double speed = 0.0;
  @override
  final double speedAccuracy = 0.0;
  @override
  final double heading = 0.0;
  @override
  final double time = 0.0;
  @override
  final bool isMock = true;
  @override
  final double verticalAccuracy = 0.0;
  @override
  final double headingAccuracy = 0.0;
  @override
  final double elapsedRealtimeNanos = 0.0;
  @override
  final double elapsedRealtimeUncertaintyNanos = 0.0;
  @override
  final int satelliteNumber = 0;
  @override
  final String provider = 'mock';

  MockLocationData({
    required this.latitude,
    required this.longitude,
  });
}

class MockServiceInstance extends Mock implements ServiceInstance {}

class MockDirectOBDOrchestrator extends Mock implements DirectOBDOrchestrator {
  final StreamController<Map<String, dynamic>> _statusController =
      StreamController<Map<String, dynamic>>.broadcast();

  @override
  Stream<Map<String, dynamic>> get statusStream => _statusController.stream;

  void simulateStatus(Map<String, dynamic> status) {
    _statusController.add(status);
  }

  @override
  void dispose() {
    _statusController.close();
  }
}

class MockFlutterBackgroundService extends Mock implements FlutterBackgroundService {
  // Override the static platform check methods
  @override
  Future<bool> configure({
    required AndroidConfiguration androidConfiguration,
    required IosConfiguration iosConfiguration,
  }) async {
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockLocation mockLocation;
  late MockFlutterBackgroundService mockService;
  late MockServiceInstance mockServiceInstance;
  late MockDirectOBDOrchestrator mockOrchestrator;
  late BackgroundService backgroundService;

  setUp(() async {
    // Set up SharedPreferences for testing
    SharedPreferences.setMockInitialValues({});

    // Create mock objects
    mockLocation = MockLocation();
    mockService = MockFlutterBackgroundService();
    mockServiceInstance = MockServiceInstance();
    mockOrchestrator = MockDirectOBDOrchestrator();
    BackgroundServiceController.setFlutterBackgroundServiceForTest(mockService);

    // Create BackgroundService instance with mocks
    backgroundService = BackgroundService(
      mockServiceInstance,
      locationService: mockLocation,
      orchestrator: mockOrchestrator,
    );

    // Register fallback values for matchers in mocktail
    registerFallbackValue(loc.LocationAccuracy.balanced);
    registerFallbackValue(0);
    registerFallbackValue(0.0);
    registerFallbackValue(<String, dynamic>{});
    registerFallbackValue(
        AndroidConfiguration(isForegroundMode: true, onStart: (_) => {}, autoStart: false));
    registerFallbackValue(IosConfiguration(autoStart: false));

    // Add this registration BEFORE trying to use 'when' on the configure method
    registerFallbackValue(AndroidConfiguration(
      onStart: (instance) {}, // This must be a function that takes ServiceInstance
      autoStart: false,
      isForegroundMode: true,
      notificationChannelId: 'test_channel',
      initialNotificationTitle: 'Test',
      initialNotificationContent: 'Test Content',
      foregroundServiceNotificationId: 1,
    ));

    registerFallbackValue(IosConfiguration(
      autoStart: false,
      onForeground: (instance) {}, // This must be a function that takes ServiceInstance
      onBackground: (instance) => Future.value(true),
    ));
  });

  tearDown(() {
    mockLocation.dispose();
    mockOrchestrator.dispose();
    BackgroundServiceController.setIsSupportedForTest(false);
  });

  group('BackgroundService Basic Functionality', () {
    test('collection frequency can be stored and retrieved', () async {
      // This test doesn't rely on the actual background service
      // It only tests the shared preferences functionality
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('collection_frequency_minutes', 30);

      expect(await BackgroundServiceController.getCollectionFrequency(), 30);
    });

    test('isServiceEnabled returns the correct value', () async {
      // Default should be false
      expect(await BackgroundServiceController.isServiceEnabled(), false);

      // After setting to true
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('background_service_enabled', true);

      expect(await BackgroundServiceController.isServiceEnabled(), true);
    });

    test('setCollectionFrequency validates the input', () async {
      expect(() async => await BackgroundServiceController.setCollectionFrequency(0),
          throwsA(isA<ArgumentError>()));
      expect(() async => await BackgroundServiceController.setCollectionFrequency(-1),
          throwsA(isA<ArgumentError>()));
    });

    test('startService invokes the service start method', () async {
      when(() => mockService.startService()).thenAnswer((_) async => true);
      BackgroundServiceController.setIsSupportedForTest(true);

      // Act
      final result = await BackgroundServiceController.startService();

      // Assert
      expect(result, true);
      verify(() => mockService.startService()).called(1);
    });

    test('stopService invokes stopService on the service', () async {
      // Arrange
      when(() => mockService.invoke(any(), any())).thenAnswer((_) async {});
      BackgroundServiceController.setIsSupportedForTest(true);

      // Act
      await BackgroundServiceController.stopService();

      // Assert
      verify(() => mockService.invoke('stopService')).called(1);
    });
  });

  group('Location-Based Collection', () {
    setUp(() {
      // Setup common mock behaviors
      when(() => mockLocation.serviceEnabled()).thenAnswer((_) async => true);
      when(() => mockLocation.hasPermission())
          .thenAnswer((_) async => loc.PermissionStatus.granted);
      when(() => mockLocation.changeSettings(
            accuracy: any(named: 'accuracy'),
            interval: any(named: 'interval'),
            distanceFilter: any(named: 'distanceFilter'),
          )).thenAnswer((_) async {
        return true;
      });

      when(() => mockService.invoke(any(), any())).thenAnswer((_) async {});
    });

    test('setupLocationBasedCollection configures service with correct parameters', () async {
      // Act
      await backgroundService.setupLocationBasedCollection();

      // Assert that the distance filter was set correctly
      verify(() => mockLocation.changeSettings(
            accuracy: loc.LocationAccuracy.balanced,
            interval: 10000,
            distanceFilter: 800.0, // LOCATION_DISTANCE_FILTER
          )).called(1);
    });

    test('setupLocationBasedCollection handles location service disabled', () async {
      // Arrange
      when(() => mockLocation.serviceEnabled()).thenAnswer((_) async => false);
      when(() => mockLocation.requestService()).thenAnswer((_) async => false);

      // Act
      await backgroundService.setupLocationBasedCollection();

      // Assert - no subscription should be created when location service is disabled
      verifyNever(() => mockLocation.changeSettings(
            accuracy: any(named: 'accuracy'),
            interval: any(named: 'interval'),
            distanceFilter: any(named: 'distanceFilter'),
          ));
    });

    test('location change triggers data collection', () async {
      // Arrange
      // Setup orchestrator mocks
      when(() => mockOrchestrator.collectData()).thenAnswer((_) async => Future.value(true));
      await backgroundService.setupLocationBasedCollection();

      // Act - simulate a location change
      final mockLocationData = MockLocationData(latitude: 37.7749, longitude: -122.4194);
      mockLocation.simulateLocationChange(mockLocationData);

      // Allow streams to propagate
      await Future.delayed(Duration(milliseconds: 10));

      // Assert
      verify(() => mockOrchestrator.collectData()).called(1);
    });
  });

  group('Service Logic', () {
    setUp(() {
      // Setup common mock behaviors for the service instance
      when(() => mockServiceInstance.invoke(any(), any())).thenAnswer((_) {});

      // Setup listener registration mocks
      final streamController = StreamController<Map<String, dynamic>?>();
      when(() => mockServiceInstance.on(any())).thenAnswer((_) => streamController.stream);

      // Setup orchestrator mocks
      when(() => mockOrchestrator.collectData()).thenAnswer((_) async => Future.value(true));
    });

    test('collectData uses orchestrator and handles success', () async {
      // Arrange
      when(() => mockOrchestrator.collectData()).thenAnswer((_) async => true);

      // Act
      final result = await backgroundService.collectData();

      // Assert
      expect(result, true);
      verify(() => mockOrchestrator.collectData()).called(1);
    });

    test('collectData handles errors and reports them', () async {
      // Arrange
      when(() => mockOrchestrator.collectData()).thenThrow(Exception('Test error'));

      // Act
      final result = await backgroundService.collectData();

      // Assert
      expect(result, false);
      verify(() => mockServiceInstance.invoke('status', any())).called(1);
    });

    test('computeNextDuration calculates retry delays correctly', () {
      // Test base case - success returns base interval
      expect(
          backgroundService.computeNextDuration(Duration(minutes: 2), Duration(minutes: 3), true),
          equals(Duration(minutes: 3)));

      // Test failure case - doubles the current interval
      expect(
          backgroundService.computeNextDuration(Duration(minutes: 2), Duration(minutes: 3), false),
          equals(Duration(minutes: 4)));

      // Test max delay limit
      expect(
          backgroundService.computeNextDuration(Duration(minutes: 3), Duration(minutes: 2), false),
          equals(Duration(minutes: 5)) // Should cap at maxDelay (5 minutes)
          );
    });
  });
}
