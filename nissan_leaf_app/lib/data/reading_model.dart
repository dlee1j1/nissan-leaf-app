class Reading {
  final int? id; // Nullable for new entries
  final DateTime timestamp;
  final double stateOfCharge;
  final double batteryHealth;
  final double batteryVoltage;
  final double batteryCapacity;
  final double estimatedRange;

  Reading({
    this.id,
    required this.timestamp,
    required this.stateOfCharge,
    required this.batteryHealth,
    required this.batteryVoltage,
    required this.batteryCapacity,
    required this.estimatedRange,
  });

  // Convert a Reading to a Map for database storage
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'timestamp': timestamp.millisecondsSinceEpoch,
      'stateOfCharge': stateOfCharge,
      'batteryHealth': batteryHealth,
      'batteryVoltage': batteryVoltage,
      'batteryCapacity': batteryCapacity,
      'estimatedRange': estimatedRange,
    };
  }

  // Create a Reading from a Map (from database)
  factory Reading.fromMap(Map<String, dynamic> map) {
    return Reading(
      id: map['id'],
      timestamp: DateTime.fromMillisecondsSinceEpoch(map['timestamp']),
      stateOfCharge: map['stateOfCharge'],
      batteryHealth: map['batteryHealth'],
      batteryVoltage: map['batteryVoltage'],
      batteryCapacity: map['batteryCapacity'],
      estimatedRange: map['estimatedRange'],
    );
  }

  // Create a Reading from OBD data
  factory Reading.fromObd(Map<String, dynamic> lbcData, Map<String, dynamic> rangeData) {
    return Reading(
      timestamp: DateTime.now(),
      stateOfCharge: (lbcData['state_of_charge'] ?? 0).toDouble(),
      batteryHealth: (lbcData['hv_battery_health'] ?? 0).toDouble(),
      batteryVoltage: (lbcData['hv_battery_voltage'] ?? 0).toDouble(),
      batteryCapacity: (lbcData['hv_battery_Ah'] ?? 0).toDouble(),
      estimatedRange: (rangeData['range_remaining'] ?? 0).toDouble(),
    );
  }

  factory Reading.fromObdMap(Map<String, dynamic> odbData) {
    return Reading(
      timestamp: odbData['timeStamp'] ?? DateTime.now(),
      stateOfCharge: (odbData['state_of_charge'] as num?)?.toDouble() ?? 00.0,
      batteryHealth: (odbData['hv_battery_health'] as num?)?.toDouble() ?? 0.0,
      batteryVoltage: (odbData['hv_battery_voltage'] as num?)?.toDouble() ?? 0.0,
      batteryCapacity: (odbData['hv_battery_Ah'] as num?)?.toDouble() ?? 0.0,
      estimatedRange: (odbData['range_remaining'] as num?)?.toDouble() ?? 0.0,
    );
  }

  // Create a copy of this Reading with the given fields replaced
  Reading copyWith({
    int? id,
    DateTime? timestamp,
    double? stateOfCharge,
    double? batteryHealth,
    double? batteryVoltage,
    double? batteryCapacity,
    double? estimatedRange,
  }) {
    return Reading(
      id: id ?? this.id,
      timestamp: timestamp ?? this.timestamp,
      stateOfCharge: stateOfCharge ?? this.stateOfCharge,
      batteryHealth: batteryHealth ?? this.batteryHealth,
      batteryVoltage: batteryVoltage ?? this.batteryVoltage,
      batteryCapacity: batteryCapacity ?? this.batteryCapacity,
      estimatedRange: estimatedRange ?? this.estimatedRange,
    );
  }
}
