import 'dart:async';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path_provider/path_provider.dart';
import 'package:simple_logger/simple_logger.dart';
import 'package:meta/meta.dart'; // For the visibleForTesting annotation
import 'reading_model.dart';

class ReadingsDatabase {
  static final ReadingsDatabase _instance = ReadingsDatabase._internal();
  static Database? _database;
  static String? _databasePath;
  static final _log = SimpleLogger();

  // Singleton pattern
  factory ReadingsDatabase({String? databasePath}) {
    // If a path is provided and database is already initialized, throw error
    if (databasePath != null && _database != null) {
      throw StateError('Cannot change database path after database is initialized');
    }

    // Set path if provided
    if (databasePath != null) {
      _databasePath = databasePath;
    }

    return _instance;
  }

  ReadingsDatabase._internal();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    // Use custom path if provided, otherwise use default location
    final path = _databasePath ?? await _getDefaultDatabasePath();

    return await openDatabase(
      path,
      version: 1,
      onCreate: _createDb,
    );
  }

  Future<String> _getDefaultDatabasePath() async {
    final documentsDirectory = await getApplicationDocumentsDirectory();
    return join(documentsDirectory.path, 'readings.db');
  }

  Future<void> _createDb(Database db, int version) async {
    await db.execute('''
      CREATE TABLE readings(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        timestamp INTEGER NOT NULL,
        stateOfCharge REAL NOT NULL,
        batteryHealth REAL NOT NULL,
        batteryVoltage REAL NOT NULL,
        batteryCapacity REAL NOT NULL,
        estimatedRange REAL NOT NULL
      )
    ''');
  }

  // For testing only
  @visibleForTesting
  static Future<void> reset() async {
    await _database?.close();
    _database = null;
    _databasePath = null;
  }

  Future<void> close() async {
    await _database?.close();
    _database = null;
  }

  // Insert a new reading
  Future<int> insertReading(Reading reading) async {
    try {
      final db = await database;
      return await db.insert('readings', reading.toMap());
    } catch (e) {
      _log.warning('Error inserting reading: $e');
      return -1;
    }
  }

  // Get the most recent reading
  Future<Reading?> getMostRecentReading() async {
    try {
      final db = await database;
      final maps = await db.query(
        'readings',
        orderBy: 'timestamp DESC',
        limit: 1,
      );

      if (maps.isNotEmpty) {
        return Reading.fromMap(maps.first);
      }
      return null;
    } catch (e) {
      _log.warning('Error getting most recent reading: $e');
      return null;
    }
  }

  // Get readings from a specific date range
  Future<List<Reading>> getReadingsInRange(DateTime start, DateTime end) async {
    try {
      final db = await database;
      final startMillis = start.millisecondsSinceEpoch;
      final endMillis = end.millisecondsSinceEpoch;

      final maps = await db.query(
        'readings',
        where: 'timestamp >= ? AND timestamp <= ?',
        whereArgs: [startMillis, endMillis],
        orderBy: 'timestamp ASC',
      );

      return maps.map((map) => Reading.fromMap(map)).toList();
    } catch (e) {
      _log.warning('Error getting readings in range: $e');
      return [];
    }
  }

  // Get readings from the last N days
  Future<List<Reading>> getReadingsFromLastDays(int days) async {
    final end = DateTime.now();
    final start = end.subtract(Duration(days: days));
    return getReadingsInRange(start, end);
  }

  // Get statistical data
  Future<Map<String, double>> getStatistics() async {
    try {
      final db = await database;

      // Get min, max, avg for state of charge
      final socStats = await db.rawQuery('''
        SELECT 
          MIN(stateOfCharge) as minSoc,
          MAX(stateOfCharge) as maxSoc,
          AVG(stateOfCharge) as avgSoc,
          MIN(batteryHealth) as minHealth,
          MAX(batteryHealth) as maxHealth,
          AVG(batteryHealth) as avgHealth,
          MIN(estimatedRange) as minRange,
          MAX(estimatedRange) as maxRange,
          AVG(estimatedRange) as avgRange
        FROM readings
      ''');

      if (socStats.isEmpty) {
        return {
          'minSoc': 0,
          'maxSoc': 0,
          'avgSoc': 0,
          'minHealth': 0,
          'maxHealth': 0,
          'avgHealth': 0,
          'minRange': 0,
          'maxRange': 0,
          'avgRange': 0,
        };
      }

      return {
        'minSoc': socStats.first['minSoc'] as double? ?? 0,
        'maxSoc': socStats.first['maxSoc'] as double? ?? 0,
        'avgSoc': socStats.first['avgSoc'] as double? ?? 0,
        'minHealth': socStats.first['minHealth'] as double? ?? 0,
        'maxHealth': socStats.first['maxHealth'] as double? ?? 0,
        'avgHealth': socStats.first['avgHealth'] as double? ?? 0,
        'minRange': socStats.first['minRange'] as double? ?? 0,
        'maxRange': socStats.first['maxRange'] as double? ?? 0,
        'avgRange': socStats.first['avgRange'] as double? ?? 0,
      };
    } catch (e) {
      _log.warning('Error getting statistics: $e');
      return {};
    }
  }

  // Get the count of readings
  Future<int> getReadingCount() async {
    try {
      final db = await database;
      final result = await db.rawQuery('SELECT COUNT(*) as count FROM readings');
      return Sqflite.firstIntValue(result) ?? 0;
    } catch (e) {
      _log.warning('Error getting reading count: $e');
      return 0;
    }
  }

  // Delete readings older than a certain date
  Future<int> deleteOldReadings(DateTime cutoffDate) async {
    try {
      final db = await database;
      return await db.delete(
        'readings',
        where: 'timestamp < ?',
        whereArgs: [cutoffDate.millisecondsSinceEpoch],
      );
    } catch (e) {
      _log.warning('Error deleting old readings: $e');
      return 0;
    }
  }
}
