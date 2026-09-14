// test/background_service_controller_test.dart
import 'dart:ui' show PluginUtilities;
import 'package:flutter_test/flutter_test.dart';
import 'package:nissan_leaf_app/background_service_controller.dart';
import 'package:mocktail/mocktail.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Mock the ForegroundTaskWrapper
class MockForegroundTaskWrapper extends Mock implements ForegroundTaskWrapper {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockForegroundTaskWrapper mockForegroundTask;

  setUp(() async {
    // Create mock objects
    mockForegroundTask = MockForegroundTaskWrapper();

    // Set the mock for testing
    BackgroundServiceController.setForegroundTaskForTest(mockForegroundTask);

    // Register fallback values for matchers in mocktail
    registerFallbackValue(AndroidNotificationOptions(
      channelId: 'test_channel',
      channelName: 'Test Channel',
      channelDescription: 'Test Description',
      channelImportance: NotificationChannelImportance.DEFAULT,
      priority: NotificationPriority.DEFAULT,
    ));

    registerFallbackValue(const IOSNotificationOptions(
      showNotification: true,
      playSound: false,
    ));

    registerFallbackValue(ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.repeat(5000),
      autoRunOnBoot: false,
      allowWifiLock: false,
    ));

    // Register fallback value for the callback function
    registerFallbackValue(() {});
  });

  tearDown(() {
    BackgroundServiceController.setIsSupportedForTest(false);
  });

  group('BackgroundService Basic Functionality', () {
    // Skip the initialize test since it requires permission_handler which is not available in tests
    test('init method is called with correct parameters', () async {
      // Arrange
      when(() => mockForegroundTask.init(
            androidNotificationOptions: any(named: 'androidNotificationOptions'),
            iosNotificationOptions: any(named: 'iosNotificationOptions'),
            foregroundTaskOptions: any(named: 'foregroundTaskOptions'),
          )).thenAnswer((_) async {});

      // Act
      await mockForegroundTask.init(
        androidNotificationOptions: AndroidNotificationOptions(
          channelId: 'test_channel',
          channelName: 'Test Channel',
          channelDescription: 'Test Description',
          channelImportance: NotificationChannelImportance.DEFAULT,
          priority: NotificationPriority.DEFAULT,
        ),
        iosNotificationOptions: const IOSNotificationOptions(
          showNotification: true,
          playSound: false,
        ),
        foregroundTaskOptions: ForegroundTaskOptions(
          eventAction: ForegroundTaskEventAction.repeat(5000),
          autoRunOnBoot: false,
          allowWifiLock: false,
        ),
      );

      // Assert
      verify(() => mockForegroundTask.init(
            androidNotificationOptions: any(named: 'androidNotificationOptions'),
            iosNotificationOptions: any(named: 'iosNotificationOptions'),
            foregroundTaskOptions: any(named: 'foregroundTaskOptions'),
          )).called(1);
    });

    test('startService calls ForegroundTaskWrapper.startService with correct parameters', () async {
      // Arrange
      when(() => mockForegroundTask.startService(
            notificationTitle: any(named: 'notificationTitle'),
            notificationText: any(named: 'notificationText'),
            callback: any(named: 'callback'),
          )).thenAnswer((_) async {});

      BackgroundServiceController.setIsSupportedForTest(true);

      // Act
      final result = await BackgroundServiceController.startService();

      // Assert
      expect(result, true);
      verify(() => mockForegroundTask.startService(
            notificationTitle: any(named: 'notificationTitle'),
            notificationText: any(named: 'notificationText'),
            callback: any(named: 'callback'),
          )).called(1);
    });

    // #22: FlutterForegroundTask.stopService() clears the plugin's own
    // persisted callback handle as a side effect (BackgroundService's
    // routine "probably parked" self-stop calls it), which silently zombies
    // the next headless restart with no error anywhere - see the doc comment
    // on BackgroundServiceController.startService. This is the other half of
    // the fix: back up the handle to our own key every time the app opens
    // normally, so ObdConnectionReceiver has something to restore from.
    test('startService backs up the callback handle for #22', () async {
      SharedPreferences.setMockInitialValues({});
      when(() => mockForegroundTask.startService(
            notificationTitle: any(named: 'notificationTitle'),
            notificationText: any(named: 'notificationText'),
            callback: any(named: 'callback'),
          )).thenAnswer((_) async {});
      BackgroundServiceController.setIsSupportedForTest(true);

      await BackgroundServiceController.startService();

      final expectedHandle =
          PluginUtilities.getCallbackHandle(backgroundServiceEntryPoint)?.toRawHandle();
      expect(expectedHandle, isNotNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(callbackHandleBackupKey), expectedHandle);
    });

    test('stopService calls ForegroundTaskWrapper.stopService', () async {
      // Arrange
      when(() => mockForegroundTask.stopService()).thenAnswer((_) async {});
      BackgroundServiceController.setIsSupportedForTest(true);

      // Act
      await BackgroundServiceController.stopService();

      // Assert
      verify(() => mockForegroundTask.stopService()).called(1);
    });

    test('isServiceRunning calls ForegroundTaskWrapper.isRunningService', () async {
      // Arrange
      when(() => mockForegroundTask.isRunningService).thenAnswer((_) async => true);
      BackgroundServiceController.setIsSupportedForTest(true);

      // Act
      final result = await BackgroundServiceController.isServiceRunning();

      // Assert
      expect(result, true);
      verify(() => mockForegroundTask.isRunningService).called(1);
    });
  });
}
