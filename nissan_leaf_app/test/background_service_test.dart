import 'package:flutter_test/flutter_test.dart';
import 'package:nissan_leaf_app/background_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    // Set up SharedPreferences for testing
    SharedPreferences.setMockInitialValues({});

    // We'll only test the SharedPreferences functionality
    // since the actual background service is platform-specific
  });

  group('BackgroundService', () {
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
}
