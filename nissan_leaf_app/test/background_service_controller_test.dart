// test/background_service_controller_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:nissan_leaf_app/background_service_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mocktail/mocktail.dart';
import 'package:flutter_background_service/flutter_background_service.dart';

// Mock classes
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

  late MockFlutterBackgroundService mockService;

  setUp(() async {
    // Set up SharedPreferences for testing
    SharedPreferences.setMockInitialValues({});

    // Create mock objects
    mockService = MockFlutterBackgroundService();
    BackgroundServiceController.setFlutterBackgroundServiceForTest(mockService);

    // Register fallback values for matchers in mocktail
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
}
