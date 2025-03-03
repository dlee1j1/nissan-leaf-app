import 'package:flutter_test/flutter_test.dart';
import 'package:nissan_leaf_app/data/reading_model.dart';
import 'package:nissan_leaf_app/data/readings_db.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late ReadingsDatabase database;

  setUpAll(() {
    // Initialize FFI for sqflite
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    // Reset any previous database state
    await ReadingsDatabase.reset();

    // Create database with in-memory path
    database = ReadingsDatabase(databasePath: inMemoryDatabasePath);

    // Access database to initialize it
    await database.database;
  });

  tearDown(() async {
    await ReadingsDatabase.reset();
  });

  group('ReadingsDatabase Tests', () {
    test('Insert and retrieve a reading', () async {
      // Create a reading
      final reading = Reading(
        timestamp: DateTime.now(),
        stateOfCharge: 85.5,
        batteryHealth: 92.0,
        batteryVoltage: 364.5,
        batteryCapacity: 56.0,
        estimatedRange: 160.0,
      );

      // Insert it
      final id = await database.insertReading(reading);
      expect(id, isPositive);

      // Retrieve it
      final retrievedReading = await database.getMostRecentReading();
      expect(retrievedReading, isNotNull);
      expect(retrievedReading!.stateOfCharge, reading.stateOfCharge);
      expect(retrievedReading.batteryHealth, reading.batteryHealth);
      expect(retrievedReading.batteryVoltage, reading.batteryVoltage);
      expect(retrievedReading.batteryCapacity, reading.batteryCapacity);
      expect(retrievedReading.estimatedRange, reading.estimatedRange);
    });

    test('Get readings in date range', () async {
      // Create readings with different timestamps
      final now = DateTime.now();
      final yesterday = now.subtract(Duration(days: 1));
      final twoDaysAgo = now.subtract(Duration(days: 2));
      final threeDaysAgo = now.subtract(Duration(days: 3));

      final readings = [
        Reading(
          timestamp: now,
          stateOfCharge: 85.0,
          batteryHealth: 92.0,
          batteryVoltage: 364.0,
          batteryCapacity: 56.0,
          estimatedRange: 160.0,
        ),
        Reading(
          timestamp: yesterday,
          stateOfCharge: 80.0,
          batteryHealth: 92.0,
          batteryVoltage: 364.0,
          batteryCapacity: 56.0,
          estimatedRange: 150.0,
        ),
        Reading(
          timestamp: twoDaysAgo,
          stateOfCharge: 75.0,
          batteryHealth: 92.0,
          batteryVoltage: 364.0,
          batteryCapacity: 56.0,
          estimatedRange: 140.0,
        ),
        Reading(
          timestamp: threeDaysAgo,
          stateOfCharge: 70.0,
          batteryHealth: 92.0,
          batteryVoltage: 364.0,
          batteryCapacity: 56.0,
          estimatedRange: 130.0,
        ),
      ];

      // Insert all readings
      for (var reading in readings) {
        await database.insertReading(reading);
      }

      // Get readings from the last 2 days
      final lastTwoDaysReadings = await database.getReadingsInRange(
        yesterday.subtract(Duration(hours: 1)),
        now.add(Duration(hours: 1)),
      );

      expect(lastTwoDaysReadings.length, 2);
      expect(lastTwoDaysReadings[0].stateOfCharge, 80.0);
      expect(lastTwoDaysReadings[1].stateOfCharge, 85.0);

      // Get all readings from the last 4 days
      final allReadings = await database.getReadingsFromLastDays(4);
      expect(allReadings.length, 4);
    });

    test('Get statistics', () async {
      // Create readings with different values
      final now = DateTime.now();
      final readings = [
        Reading(
          timestamp: now.subtract(Duration(hours: 3)),
          stateOfCharge: 90.0,
          batteryHealth: 94.0,
          batteryVoltage: 365.0,
          batteryCapacity: 57.0,
          estimatedRange: 170.0,
        ),
        Reading(
          timestamp: now.subtract(Duration(hours: 2)),
          stateOfCharge: 80.0,
          batteryHealth: 93.0,
          batteryVoltage: 360.0,
          batteryCapacity: 56.0,
          estimatedRange: 150.0,
        ),
        Reading(
          timestamp: now.subtract(Duration(hours: 1)),
          stateOfCharge: 70.0,
          batteryHealth: 92.0,
          batteryVoltage: 355.0,
          batteryCapacity: 55.0,
          estimatedRange: 130.0,
        ),
      ];

      // Insert all readings
      for (var reading in readings) {
        await database.insertReading(reading);
      }

      // Get statistics
      final stats = await database.getStatistics();

      expect(stats['minSoc'], 70.0);
      expect(stats['maxSoc'], 90.0);
      expect(stats['avgSoc'], 80.0);

      expect(stats['minHealth'], 92.0);
      expect(stats['maxHealth'], 94.0);
      expect(stats['avgHealth'], 93.0);

      expect(stats['minRange'], 130.0);
      expect(stats['maxRange'], 170.0);
      expect(stats['avgRange'], 150.0);
    });

    test('Delete old readings', () async {
      // Create readings with different timestamps
      final now = DateTime.now();
      final oneWeekAgo = now.subtract(Duration(days: 7));
      final twoWeeksAgo = now.subtract(Duration(days: 14));

      final readings = [
        Reading(
          timestamp: now,
          stateOfCharge: 85.0,
          batteryHealth: 92.0,
          batteryVoltage: 364.0,
          batteryCapacity: 56.0,
          estimatedRange: 160.0,
        ),
        Reading(
          timestamp: oneWeekAgo,
          stateOfCharge: 80.0,
          batteryHealth: 92.0,
          batteryVoltage: 364.0,
          batteryCapacity: 56.0,
          estimatedRange: 150.0,
        ),
        Reading(
          timestamp: twoWeeksAgo,
          stateOfCharge: 75.0,
          batteryHealth: 93.0,
          batteryVoltage: 365.0,
          batteryCapacity: 57.0,
          estimatedRange: 140.0,
        ),
      ];

      // Insert all readings
      for (var reading in readings) {
        await database.insertReading(reading);
      }

      // Verify we have 3 readings
      var count = await database.getReadingCount();
      expect(count, 3);

      // Delete readings older than 10 days
      final deleted = await database.deleteOldReadings(
        now.subtract(Duration(days: 10)),
      );
      expect(deleted, 1);

      // Verify we now have 2 readings
      count = await database.getReadingCount();
      expect(count, 2);

      // Get all readings
      final remainingReadings = await database.getReadingsFromLastDays(30);
      expect(remainingReadings.length, 2);

      // Verify the two-week-old reading is gone
      final oldestTimestamp = remainingReadings
          .map((r) => r.timestamp.millisecondsSinceEpoch)
          .reduce((a, b) => a < b ? a : b);

      expect(oldestTimestamp, oneWeekAgo.millisecondsSinceEpoch);
    });

    test('Throws error when trying to change database path after initialization', () async {
      // Database is already initialized in setUp

      // Try to change the path
      expect(
        () => ReadingsDatabase(databasePath: 'new_path.db'),
        throwsA(isA<StateError>()),
      );
    });
  });
}
