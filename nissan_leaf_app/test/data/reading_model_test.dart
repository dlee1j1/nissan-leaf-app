import 'package:flutter_test/flutter_test.dart';
import 'package:nissan_leaf_app/data/reading_model.dart';

void main() {
  group('Reading Model Tests', () {
    test('Reading creation from constructor', () {
      final now = DateTime.now();
      final reading = Reading(
        id: 1,
        timestamp: now,
        stateOfCharge: 85.5,
        batteryHealth: 92.0,
        batteryVoltage: 364.5,
        batteryCapacity: 56.0,
        estimatedRange: 160.0,
      );

      expect(reading.id, 1);
      expect(reading.timestamp, now);
      expect(reading.stateOfCharge, 85.5);
      expect(reading.batteryHealth, 92.0);
      expect(reading.batteryVoltage, 364.5);
      expect(reading.batteryCapacity, 56.0);
      expect(reading.estimatedRange, 160.0);
    });

    test('Reading conversion to/from Map', () {
      final now = DateTime.now();
      final originalReading = Reading(
        id: 1,
        timestamp: now,
        stateOfCharge: 85.5,
        batteryHealth: 92.0,
        batteryVoltage: 364.5,
        batteryCapacity: 56.0,
        estimatedRange: 160.0,
      );

      final map = originalReading.toMap();
      final convertedReading = Reading.fromMap(map);

      expect(convertedReading.id, originalReading.id);
      expect(convertedReading.timestamp.millisecondsSinceEpoch,
          originalReading.timestamp.millisecondsSinceEpoch);
      expect(convertedReading.stateOfCharge, originalReading.stateOfCharge);
      expect(convertedReading.batteryHealth, originalReading.batteryHealth);
      expect(convertedReading.batteryVoltage, originalReading.batteryVoltage);
      expect(convertedReading.batteryCapacity, originalReading.batteryCapacity);
      expect(convertedReading.estimatedRange, originalReading.estimatedRange);
    });

    test('Reading creation from OBD data', () {
      final lbcData = {
        'state_of_charge': 85,
        'hv_battery_health': 92,
        'hv_battery_voltage': 364,
        'hv_battery_Ah': 56,
      };

      final rangeData = {
        'range_remaining': 160.0,
      };

      final reading = Reading.fromObd(lbcData, rangeData);

      expect(reading.stateOfCharge, 85.0);
      expect(reading.batteryHealth, 92.0);
      expect(reading.batteryVoltage, 364.0);
      expect(reading.batteryCapacity, 56.0);
      expect(reading.estimatedRange, 160.0);
    });

    test('Reading handles null OBD values', () {
      final lbcData = <String, dynamic>{};
      final rangeData = <String, dynamic>{};

      final reading = Reading.fromObd(lbcData, rangeData);

      expect(reading.stateOfCharge, 0.0);
      expect(reading.batteryHealth, 0.0);
      expect(reading.batteryVoltage, 0.0);
      expect(reading.batteryCapacity, 0.0);
      expect(reading.estimatedRange, 0.0);
    });

    test('Reading copyWith works correctly', () {
      final now = DateTime.now();
      final reading = Reading(
        id: 1,
        timestamp: now,
        stateOfCharge: 85.5,
        batteryHealth: 92.0,
        batteryVoltage: 364.5,
        batteryCapacity: 56.0,
        estimatedRange: 160.0,
      );

      final newTimestamp = DateTime.now().add(Duration(hours: 1));
      final updatedReading = reading.copyWith(
        stateOfCharge: 80.0,
        timestamp: newTimestamp,
      );

      expect(updatedReading.id, 1);
      expect(updatedReading.timestamp, newTimestamp);
      expect(updatedReading.stateOfCharge, 80.0);
      expect(updatedReading.batteryHealth, 92.0);
      expect(updatedReading.batteryVoltage, 364.5);
      expect(updatedReading.batteryCapacity, 56.0);
      expect(updatedReading.estimatedRange, 160.0);
    });
  });
}
