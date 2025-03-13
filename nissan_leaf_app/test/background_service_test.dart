import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';
import 'package:nissan_leaf_app/background_service.dart';
import 'package:flutter_background_service/flutter_background_service.dart';

// Mock classes
class MockWorkmanager extends Mock implements Workmanager {}

class MockFlutterBackgroundService extends Mock implements FlutterBackgroundService {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MockWorkmanager mockWorkmanager;
  late MockFlutterBackgroundService mockFlutterBackgroundService;

  setUp(() async {
    // Set up SharedPreferences for testing
    SharedPreferences.setMockInitialValues({});

    // Set up WorkManager mocks
    mockWorkmanager = MockWorkmanager();
    BackgroundService.setWorkmanagerForTesting(mockWorkmanager);
    BackgroundService.setShouldRequestPermission(false);

    mockFlutterBackgroundService = MockFlutterBackgroundService();
    BackgroundService.setBackgroundServiceForTesting(mockFlutterBackgroundService);
    when(() => mockFlutterBackgroundService.startService()).thenAnswer((_) async => true);

    // Register fallback values for any() matchers
    registerFallbackValue(const Duration(minutes: 15));
    registerFallbackValue(Constraints(networkType: NetworkType.not_required));
    registerFallbackValue(ExistingWorkPolicy.replace);
  });

  group('BackgroundService - SharedPreferences tests', () {
    test('collection frequency can be stored and retrieved', () async {
      // This test doesn't rely on the actual background service
      // It only tests the shared preferences functionality
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('collection_frequency_minutes', 30);

      expect(await BackgroundService.getCollectionFrequency(), 30);
    });

    test('isServiceEnabled returns the correct value', () async {
      // Default should be false
      expect(await BackgroundService.isServiceEnabled(), false);

      // After setting to true
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('background_service_enabled', true);

      expect(await BackgroundService.isServiceEnabled(), true);
    });

    test('setCollectionFrequency validates the input', () async {
      expect(() async => await BackgroundService.setCollectionFrequency(0),
          throwsA(isA<ArgumentError>()));
      expect(() async => await BackgroundService.setCollectionFrequency(-1),
          throwsA(isA<ArgumentError>()));
    });
  });

  group('BackgroundService - WorkManager tests', () {
    test('_computeNextInterval returns base duration on success', () {
      final result = BackgroundService.computeNextInterval(
          const Duration(minutes: 1), const Duration(minutes: 2), true);

      expect(result, equals(const Duration(minutes: 1)));
    });

    test('_computeNextInterval doubles previous duration on failure', () {
      final result = BackgroundService.computeNextInterval(
          const Duration(minutes: 1), const Duration(minutes: 2), false);

      expect(result, equals(const Duration(minutes: 4)));
    });

    test('_computeNextInterval caps doubled duration at 5 minutes when base is less than 5', () {
      final result = BackgroundService.computeNextInterval(
          const Duration(minutes: 3), const Duration(minutes: 3), false);

      expect(result, equals(const Duration(minutes: 5)));
    });

    test('_computeNextInterval uses base duration when it exceeds 5 minutes', () {
      final result = BackgroundService.computeNextInterval(
          const Duration(minutes: 10), const Duration(minutes: 3), false);

      // Even though doubling would be 6 minutes, we use base (10) because it's > 5
      expect(result, equals(const Duration(minutes: 10)));
    });

    test('startService initializes WorkManager and schedules task', () async {
      // Set up mock shared preferences
      SharedPreferences.setMockInitialValues({
        'collection_frequency_minutes': 15,
      });

      // Set up WorkManager mocks
      when(() => mockWorkmanager.initialize(any())).thenAnswer((_) async {});
      when(() => mockWorkmanager.registerOneOffTask(
            any(),
            any(),
            initialDelay: any(named: 'initialDelay'),
            constraints: any(named: 'constraints'),
            existingWorkPolicy: any(named: 'existingWorkPolicy'),
          )).thenAnswer((_) async {});

      // Call the method under test
      await BackgroundService.startService();

      // Verify WorkManager was initialized and task was scheduled
      verify(() => mockWorkmanager.initialize(any())).called(1);

      // Verify task was scheduled with the right parameters
      final capturedDelays = verify(() => mockWorkmanager.registerOneOffTask(
            any(),
            any(),
            initialDelay: captureAny(named: 'initialDelay'),
            constraints: any(named: 'constraints'),
            existingWorkPolicy: any(named: 'existingWorkPolicy'),
          )).captured;

      // Should have scheduled with base duration of 15 minutes
      expect(capturedDelays.first, equals(const Duration(minutes: 15)));
    });

    test('stopService cancels all WorkManager tasks', () async {
      // Set up mock shared preferences
      SharedPreferences.setMockInitialValues({});

      // Set up WorkManager mocks
      when(() => mockWorkmanager.cancelAll()).thenAnswer((_) async {});

      // Call the method under test
      await BackgroundService.stopService();

      // Verify WorkManager tasks were cancelled
      verify(() => mockWorkmanager.cancelAll()).called(1);
    });

    test('setCollectionFrequency updates WorkManager task when service is running', () async {
      // Mock FlutterBackgroundService for isRunning check
      // Set up mocks
      when(() => mockFlutterBackgroundService.isRunning()).thenAnswer((_) async => true);
      when(() => mockFlutterBackgroundService.invoke(any(), any())).thenAnswer((_) async {});

      // Set up shared preferences
      SharedPreferences.setMockInitialValues({});

      // Call the method under test
      await BackgroundService.setCollectionFrequency(30);

      // Verify service was invoked with new frequency
      verify(() => mockFlutterBackgroundService.invoke('updateFrequency', {'minutes': 30}))
          .called(1);

      // Reset mock
      reset(mockFlutterBackgroundService);

      // Mock service not running
      when(() => mockFlutterBackgroundService.isRunning()).thenAnswer((_) async => false);

      // Call method again
      await BackgroundService.setCollectionFrequency(45);

      // Verify service was NOT invoked when not running
      verifyNever(() => mockFlutterBackgroundService.invoke(any(), any()));
    });
  });
}
