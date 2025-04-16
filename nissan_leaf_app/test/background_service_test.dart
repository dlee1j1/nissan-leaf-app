import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:nissan_leaf_app/background_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mocktail/mocktail.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:location/location.dart' as loc;
import 'package:nissan_leaf_app/data_orchestrator.dart';

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

// We'll use the actual TaskStarter enum

// Create a custom mock implementation for DirectOBDOrchestrator
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockLocation mockLocation;
  late TaskStarter mockTaskStarter;
  late MockDirectOBDOrchestrator mockOrchestrator;
  late BackgroundService backgroundService;

  setUp(() async {
    // Set up SharedPreferences for testing
    SharedPreferences.setMockInitialValues({});

    // Create mock objects
    mockLocation = MockLocation();
    mockTaskStarter = TaskStarter.developer;
    mockOrchestrator = MockDirectOBDOrchestrator();

    // Register fallback values for matchers in mocktail
    registerFallbackValue(loc.LocationAccuracy.balanced);
    registerFallbackValue(0);
    registerFallbackValue(0.0);
    registerFallbackValue(<String, dynamic>{});
    registerFallbackValue(DateTime.now());
  });

  tearDown(() {
    mockLocation.dispose();
    mockOrchestrator.dispose();
  });

  group('Location-Based Collection', () {
    setUp(() {
      // Setup common mock behaviors
      when(() => mockLocation.serviceEnabled()).thenAnswer((_) async => true);
      when(() => mockLocation.requestService()).thenAnswer((_) async => true);
      when(() => mockLocation.hasPermission())
          .thenAnswer((_) async => loc.PermissionStatus.granted);

      // This is the critical fix - properly mock the changeSettings method
      when(() => mockLocation.changeSettings(
            accuracy: any(named: 'accuracy'),
            distanceFilter: any(named: 'distanceFilter'),
          )).thenAnswer((_) async => true);

      // Mock the orchestrator collectData method
      when(() => mockOrchestrator.collectData()).thenAnswer((_) async => true);
    });

    test('onStart configures location service with correct parameters', () async {
      // Reset the mock to ensure clean state
      reset(mockLocation);

      // Re-setup the mock
      when(() => mockLocation.serviceEnabled()).thenAnswer((_) async => true);
      when(() => mockLocation.requestService()).thenAnswer((_) async => true);
      when(() => mockLocation.hasPermission())
          .thenAnswer((_) async => loc.PermissionStatus.granted);
      when(() => mockLocation.changeSettings(
            accuracy: any(named: 'accuracy'),
            distanceFilter: any(named: 'distanceFilter'),
          )).thenAnswer((_) async => true);

      // Create the BackgroundService instance
      backgroundService = BackgroundService(
        orchestrator: mockOrchestrator,
        locationService: mockLocation,
      );

      // Call onStart to trigger the location setup
      await backgroundService.onStart(DateTime.now(), mockTaskStarter);

      // Verify that the distance filter was set correctly
      verify(() => mockLocation.changeSettings(
          accuracy: any(named: 'accuracy'), distanceFilter: LOCATION_DISTANCE_FILTER)).called(1);
    });

    test('setupLocationBasedCollection handles location service disabled', () async {
      // Arrange - override the default mock setup
      when(() => mockLocation.serviceEnabled()).thenAnswer((_) async => false);
      when(() => mockLocation.requestService()).thenAnswer((_) async => false);

      // Create the BackgroundService instance
      backgroundService = BackgroundService(
        orchestrator: mockOrchestrator,
        locationService: mockLocation,
      );

      // Manually call onStart to simulate service start
      await backgroundService.onStart(DateTime.now(), mockTaskStarter);

      // Give time for the asynchronous initialization to complete
      await Future.delayed(const Duration(milliseconds: 10));

      // Verify changeSettings was never called
      verifyNever(() => mockLocation.changeSettings(
            accuracy: any(named: 'accuracy'),
            distanceFilter: any(named: 'distanceFilter'),
          ));
    });

    test('location change triggers data collection', () async {
      // Create the BackgroundService instance
      backgroundService = BackgroundService();
      backgroundService.setOrchestratorForTesting(mockOrchestrator);

      // Manually call onStart to simulate service start
      await backgroundService.onStart(DateTime.now(), mockTaskStarter);

      // Reset the mock to clear the initial call during onStart
      reset(mockOrchestrator);
      when(() => mockOrchestrator.collectData()).thenAnswer((_) async => true);

      // Update to a frequency that will trigger location-based collection
      backgroundService.updateCollectionFrequency(60);

      // Simulate a location change
      final mockLocationData = MockLocationData(latitude: 37.7749, longitude: -122.4194);
      mockLocation.simulateLocationChange(mockLocationData);

      // Allow time for the change to propagate
      await Future.delayed(const Duration(milliseconds: 100));

      // Verify data collection was triggered
      verify(() => mockOrchestrator.collectData()).called(greaterThan(0));
    });
  });

  group('Service Logic', () {
    setUp(() {
      // Setup common mock behaviors
      when(() => mockLocation.serviceEnabled()).thenAnswer((_) async => true);
      when(() => mockLocation.requestService()).thenAnswer((_) async => true);
      when(() => mockLocation.hasPermission())
          .thenAnswer((_) async => loc.PermissionStatus.granted);

      when(() => mockLocation.changeSettings(
            accuracy: any(named: 'accuracy'),
            distanceFilter: any(named: 'distanceFilter'),
          )).thenAnswer((_) async => true);

      // Create the BackgroundService instance
      backgroundService = BackgroundService(
        orchestrator: mockOrchestrator,
        locationService: mockLocation,
      );

      // Manually call onStart to simulate service start
      backgroundService.onStart(DateTime.now(), mockTaskStarter);

      // Reset the mock to clear the initial call during onStart
      reset(mockOrchestrator);
      when(() => mockOrchestrator.collectData()).thenAnswer((_) async => true);
    });

    test('collectData uses orchestrator and handles success', () async {
      // Reset the mock to ensure clean state
      reset(mockOrchestrator);

      // Clear any previous interactions
      clearInteractions(mockOrchestrator);

      // Setup the mock behavior
      when(() => mockOrchestrator.collectData()).thenAnswer((_) async => true);
      backgroundService.setOrchestratorForTesting(mockOrchestrator);
      // Act
      final result = await backgroundService.collectData();

      // Assert
      expect(result, true);
      verify(() => mockOrchestrator.collectData()).called(1);
    });

    test('collectData handles errors and reports them', () async {
      // This test verifies that the collectData method properly handles exceptions

      // Create a fresh instance with a mock that will throw an exception
      final testOrchestrator = MockDirectOBDOrchestrator();

      // Configure the mock to throw an exception when collectData is called
      when(() => testOrchestrator.collectData())
          .thenAnswer((_) => Future.error(Exception('Test error')));
      backgroundService.setOrchestratorForTesting(testOrchestrator);

      // Call collectData directly and verify it returns false on error
      final result = await backgroundService.collectData();
      expect(result, false);
    });

    test('computeNextDuration calculates retry delays correctly', () {
      // Test base case - success returns base interval
      expect(
          backgroundService.computeNextDuration(Duration(minutes: 2), Duration(minutes: 1), true),
          equals(Duration(minutes: 1)));

      // Test failure case - doubles the current interval
      expect(
          backgroundService.computeNextDuration(Duration(minutes: 2), Duration(minutes: 3), false),
          equals(Duration(minutes: 4)));

      // Test max delay limit
      expect(
          backgroundService.computeNextDuration(Duration(minutes: 25), Duration(minutes: 3), false),
          equals(Duration(minutes: 30)) // Should cap at maxDelay (30 minutes)
          );
    });
  });
}
