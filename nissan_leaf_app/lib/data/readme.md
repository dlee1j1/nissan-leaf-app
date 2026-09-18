# Data Persistence Layer

This directory contains the data models and database implementation for the Nissan Leaf Battery Tracker.

*[Return to main documentation](../../README.md)*

## Architecture

The data layer follows a straightforward design:

```
┌─────────────────┐     ┌─────────────────┐     
│   Reading Model │◄────┤  ReadingsDatabase│     
│                 │     │                 │     
└─────────────────┘     └─────────────────┘     
```

## Components

### `reading_model.dart`

Defines the `Reading` class that represents a single data point of battery information. Each reading contains:

- `id`: Database identifier (auto-generated)
- `timestamp`: When the reading was taken
- `stateOfCharge`: Battery charge percentage (0-100%)
- `batteryHealth`: Battery health percentage (0-100%)
- `batteryVoltage`: High-voltage battery voltage (volts)
- `batteryCapacity`: High-voltage battery capacity (Ah)
- `estimatedRange`: Estimated driving range (km) - known unreliable, see below
- `speed`, `odometer`, `ambientTemp`, `l1l2Charges`, `quickCharges`: nullable
  analytics fields. Nullable because the OBD reads behind them are
  best-effort (`BluetoothDeviceManager.collectCarData()`), so a given
  reading may be missing some or all of them even on current app versions,
  not just on rows written before they existed.

The model provides several factory methods:
- `Reading.fromMap()`: Create from a database record
- `Reading.fromObd()`: Create from OBD command responses
- `Reading.fromObdMap()`: Create from a merged OBD data map

Example:
```dart
// Create from OBD data
final reading = Reading.fromObdMap({
  'state_of_charge': 85,
  'hv_battery_health': 92,
  'hv_battery_voltage': 364,
  'hv_battery_Ah': 56,
  'range_remaining': 150,
  'timestamp': DateTime.now().millisecondsSinceEpoch,
});

// Create manually
final reading = Reading(
  timestamp: DateTime.now(),
  stateOfCharge: 85.0,
  batteryHealth: 92.0,
  batteryVoltage: 364.0,
  batteryCapacity: 56.0,
  estimatedRange: 150.0,
);
```

### `readings_db.dart`

Implements SQLite database operations for storing and retrieving readings. Features:

- Singleton pattern for app-wide access
- Functions for adding new readings
- Queries for retrieving historical data
- Statistical functions for analyzing data

Example usage:
```dart
final db = ReadingsDatabase();

// Store a reading
final id = await db.insertReading(reading);

// Get most recent reading
final latestReading = await db.getMostRecentReading();

// Get readings from last 7 days
final recentReadings = await db.getReadingsFromLastDays(7);

// Get statistics
final stats = await db.getStatistics();
print('Average SOC: ${stats['avgSoc']}%');
```

## Database Schema

The database uses a single table `readings` with the following schema:

```sql
CREATE TABLE readings(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  timestamp INTEGER NOT NULL,
  stateOfCharge REAL NOT NULL,
  batteryHealth REAL NOT NULL,
  batteryVoltage REAL NOT NULL,
  batteryCapacity REAL NOT NULL,
  estimatedRange REAL NOT NULL,
  speed REAL,
  odometer INTEGER,
  ambientTemp REAL,
  l1l2Charges INTEGER,
  quickCharges INTEGER
)
```

The five analytics columns were added in schema version 2 via `onUpgrade`
in `readings_db.dart` - see "Extending the Data Model" below for the
pattern, now exercised for real rather than just described.

### `estimatedRange` is not populated

The OBD command that fed it (`03220e24`, header `743`) returned a frozen
value regardless of actual SOC or driving, so it was removed rather than
left half-working - see the "REMOVED" note by `extractInt` in
`obd_command.dart`. The field and DB column still exist (nothing currently
writes them); the dashboard's display of the car's own dash range is
unaffected.

## Session Management

The app uses a simple session tracking mechanism to group related readings:

1. A session ID is created when data collection starts
2. The session persists for 30 minutes of inactivity
3. After 30 minutes without new readings, a new session is created

Sessions are useful for:
- Identifying charging cycles
- Grouping trip data
- Analyzing battery behavior in specific contexts

## Extending the Data Model

If you need to add new metrics to track:

1. Add the field to the `Reading` class in `reading_model.dart`
2. Update the `toMap()` and factory methods to include the new field
3. Modify the database schema in `readings_db.dart`
4. Add migration code if needed for existing databases

The speed/odometer/ambientTemp/l1l2Charges/quickCharges fields (schema
version 2) are a real, checked-in example of this whole pattern end to
end - `reading_model.dart`, `readings_db.dart`'s `_upgradeDb()`, and
`test/data/readings_db_test.dart`'s migration test are all worth reading
alongside this walkthrough.

Example for adding a battery temperature field:

```dart
// In reading_model.dart
class Reading {
  // Add the new field
  final double batteryTemperature;

  Reading({
    this.id,
    required this.timestamp,
    required this.stateOfCharge,
    required this.batteryHealth,
    required this.batteryVoltage,
    required this.batteryCapacity,
    required this.estimatedRange,
    required this.batteryTemperature, // New field
  });

  // Update toMap()
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'timestamp': timestamp.millisecondsSinceEpoch,
      // ... existing fields
      'batteryTemperature': batteryTemperature,
    };
  }

  // Update factory methods
  factory Reading.fromMap(Map<String, dynamic> map) {
    return Reading(
      // ... existing fields
      batteryTemperature: map['batteryTemperature'] ?? 0.0,
    );
  }
}

// In readings_db.dart, update _createDb()
Future<void> _createDb(Database db, int version) async {
  await db.execute('''
    CREATE TABLE readings(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      timestamp INTEGER NOT NULL,
      stateOfCharge REAL NOT NULL,
      batteryHealth REAL NOT NULL,
      batteryVoltage REAL NOT NULL,
      batteryCapacity REAL NOT NULL,
      estimatedRange REAL NOT NULL,
      batteryTemperature REAL NOT NULL
    )
  ''');
}
```

## Performance Considerations

The database is designed to handle thousands of readings efficiently, but consider:

1. Implementing a data cleanup policy to remove old readings (e.g., `deleteOldReadings()`)
2. Using indices for frequent query patterns if performance becomes an issue
3. Being mindful of query patterns in UI code to avoid excessive database access
